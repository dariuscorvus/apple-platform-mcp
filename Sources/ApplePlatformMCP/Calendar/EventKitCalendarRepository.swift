import EventKit
import Foundation

public actor EventKitCalendarRepository: CalendarRepository {
  private let store: EKEventStore
  public init() { store = EKEventStore() }
  public static func currentAuthorizationStatus() -> CalendarAccess {
    CalendarAccess.normalized(EKEventStore.authorizationStatus(for: .event).rawValue)
  }
  public func authorizationStatus() async -> CalendarAccess { Self.currentAuthorizationStatus() }
  public func requestFullAccess() async throws -> CalendarAccess {
    let current = Self.currentAuthorizationStatus()
    if current == .fullAccess { return current }
    // Write-only users may explicitly upgrade to Full Access through this setup command.
    guard current == .notDetermined || current == .writeOnly else {
      throw CalendarError("calendarPermissionDenied")
    }
    let granted: Bool
    do {
      if #available(macOS 14.0, *) {
        granted = try await withCheckedThrowingContinuation { continuation in
          store.requestFullAccessToEvents { granted, error in
            if error != nil {
              continuation.resume(throwing: CalendarError("calendarPermissionDenied"))
            } else {
              continuation.resume(returning: granted)
            }
          }
        }
      } else {
        granted = try await withCheckedThrowingContinuation { continuation in
          store.requestAccess(to: .event) { granted, error in
            if error != nil {
              continuation.resume(throwing: CalendarError("calendarPermissionDenied"))
            } else {
              continuation.resume(returning: granted)
            }
          }
        }
      }
    } catch { throw CalendarError("calendarPermissionDenied") }
    store.reset()
    guard granted, Self.currentAuthorizationStatus() == .fullAccess else {
      throw CalendarError("calendarPermissionDenied")
    }
    return .fullAccess
  }
  private func requireAccess() throws {
    switch Self.currentAuthorizationStatus() {
    case .fullAccess: return
    case .notDetermined: throw CalendarError("calendarPermissionRequired")
    case .writeOnly: throw CalendarError("calendarPermissionWriteOnly")
    case .denied, .restricted: throw CalendarError("calendarPermissionDenied")
    case .unavailable: throw CalendarError("calendarUnavailable")
    }
  }
  public func listCalendars() async throws -> [CalendarDescriptor] {
    try requireAccess()
    store.reset()
    return try store.calendars(for: .event).map(Self.descriptor)
  }
  private nonisolated static func descriptor(_ calendar: EKCalendar) throws -> CalendarDescriptor {
    guard let source = calendar.source, !source.sourceIdentifier.isEmpty,
      !calendar.calendarIdentifier.isEmpty
    else { throw CalendarError("calendarUnavailable") }
    return .init(
      id: try CalendarReferenceCodec.calendar(
        source: source.sourceIdentifier, calendar: calendar.calendarIdentifier),
      name: calendar.title, source: source.title, canWrite: calendar.allowsContentModifications)
  }
  private func resolveCalendar(_ id: String) throws -> EKCalendar {
    let a = try CalendarReferenceCodec.decode(id, kind: "calendar")
    guard let calendar = store.calendar(withIdentifier: a.calendar),
      calendar.source?.sourceIdentifier == a.source,
      calendar.allowedEntityTypes.contains(.event)
    else { throw CalendarError("calendarNotFound") }
    return calendar
  }
  public func writableCalendar(id: String) async throws -> CalendarDescriptor {
    try requireAccess()
    store.reset()
    let calendar = try resolveCalendar(id)
    guard calendar.allowsContentModifications else { throw CalendarError("calendarNotWritable") }
    return try Self.descriptor(calendar)
  }
  public func scan(window: CalendarWindow, calendarIDs: [String]?, maximum: Int) async throws
    -> CalendarScan
  {
    try requireAccess()
    store.reset()
    let calendars: [EKCalendar]
    if let calendarIDs {
      guard !calendarIDs.isEmpty else { throw CalendarError("calendarInvalidInput") }
      calendars = try Set(calendarIDs).sorted().map(resolveCalendar)
    } else {
      calendars = store.calendars(for: .event)
    }
    return try collect(window: window, calendars: calendars, maximum: maximum)
  }
  private func collect(window: CalendarWindow, calendars: [EKCalendar], maximum: Int) throws
    -> CalendarScan
  {
    guard maximum > 0 else { throw CalendarError("calendarInvalidInput") }
    let ids = try calendars.map { try Self.descriptor($0).id }.sorted()
    if calendars.isEmpty { return .init(records: [], calendarIDs: [], complete: true) }
    let predicate = store.predicateForEvents(
      withStart: window.start, end: window.end, calendars: calendars)
    let accumulator = CalendarScanAccumulator(maximum: maximum)
    // EventKit documents synchronous enumeration. The locked collector also avoids
    // sharing mutable captures through the Objective-C callback boundary.
    store.enumerateEvents(matching: predicate) { event, stop in
      if accumulator.shouldStop() {
        stop.pointee = true
        return
      }
      do {
        let record = try Self.record(event)
        if ids.contains(record.event.calendarID),
          window.overlaps(start: record.start, end: record.end)
        {
          accumulator.append(record)
        } else if !ids.contains(record.event.calendarID) {
          accumulator.markIncomplete()
        }
      } catch { accumulator.markIncomplete() }
    }
    return accumulator.snapshot(calendarIDs: ids)
  }
  public func getEvent(id: String) async throws -> CalendarEventRecord {
    try requireAccess()
    store.reset()
    let a = try CalendarReferenceCodec.decode(id, kind: "event")
    let calendarID = try CalendarReferenceCodec.calendar(source: a.source, calendar: a.calendar)
    let calendar = try resolveCalendar(calendarID)
    guard
      let anchor = a.start.flatMap({ CalendarTimeRange.instant($0, TimeZone(secondsFromGMT: 0)!) })
    else { throw CalendarError("calendarInvalidReference") }
    let window = CalendarWindow(
      start: anchor.addingTimeInterval(-1), end: anchor.addingTimeInterval(1),
      timeZone: TimeZone(secondsFromGMT: 0)!)
    let scan = try collect(window: window, calendars: [calendar], maximum: 10_000)
    return try CalendarOccurrenceResolver.resolve(a, scan: scan)
  }
  public func createEvent(_ request: CalendarCreateRequest) async throws -> CalendarEventRecord {
    try requireAccess()
    store.reset()
    let calendar = try resolveCalendar(request.calendarID)
    guard calendar.allowsContentModifications else { throw CalendarError("calendarNotWritable") }
    let window = try request.time.validated()
    let event = EKEvent(eventStore: store)
    event.calendar = calendar
    event.title = request.title
    event.timeZone = window.timeZone
    event.isAllDay = request.time.allDay
    event.startDate = window.start
    event.endDate = window.end
    event.location = request.location
    event.notes = request.notes
    event.alarms = []
    event.recurrenceRules = []
    event.availability = .busy
    do { try store.save(event, span: .thisEvent, commit: true) } catch {
      throw CalendarError("calendarWriteFailed")
    }
    let saved = try Self.record(event)
    if request.time.allDay {
      guard saved.event.time.start == request.time.start, saved.event.time.end == request.time.end
      else { throw CalendarError("calendarCreationOutcomeUnknown") }
    } else {
      guard abs(saved.start.timeIntervalSince(window.start)) < 0.001,
        abs(saved.end.timeIntervalSince(window.end)) < 0.001
      else { throw CalendarError("calendarCreationOutcomeUnknown") }
    }
    return saved
  }
  private nonisolated static func record(_ event: EKEvent) throws -> CalendarEventRecord {
    guard let calendar = event.calendar, let source = calendar.source,
      let id = event.eventIdentifier, !id.isEmpty,
      let start = event.startDate, let end = event.endDate, end > start
    else { throw CalendarError("calendarUnavailable") }
    let zone = event.isAllDay ? TimeZone.current : event.timeZone ?? TimeZone.current
    let time = CalendarTimeRange(
      start: event.isAllDay
        ? CalendarTimeRange.dateString(start, zone) : CalendarTimeRange.timestamp(start, zone),
      end: event.isAllDay
        ? CalendarTimeRange.dateString(end, zone) : CalendarTimeRange.timestamp(end, zone),
      timeZone: zone.identifier, allDay: event.isAllDay)
    let status: String
    switch event.status {
    case .canceled: status = "cancelled"
    case .confirmed: status = "confirmed"
    case .tentative: status = "tentative"
    default: status = "unknown"
    }
    let availability: String
    switch event.availability {
    case .free: availability = "free"
    case .busy: availability = "busy"
    case .tentative: availability = "tentative"
    case .unavailable: availability = "unavailable"
    default: availability = "unknown"
    }
    let recurring = event.hasRecurrenceRules || event.isDetached
    let reference = try CalendarReferenceCodec.event(
      source: source.sourceIdentifier, calendar: calendar.calendarIdentifier,
      event: id, occurrence: recurring ? event.occurrenceDate : nil, start: start, end: end)
    let item = CalendarEvent(
      id: reference, calendarID: try Self.descriptor(calendar).id, title: event.title ?? "",
      time: time,
      timeZoneSource: event.isAllDay || event.timeZone == nil ? "event_store_default" : "event",
      location: event.location, notes: event.notes, recurring: recurring,
      detached: event.isDetached, status: status, availability: availability)
    return .init(event: item, start: start, end: end)
  }
}

private final class CalendarScanAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private let maximum: Int
  private var inspected = 0
  private var complete = true
  private var records: [CalendarEventRecord] = []
  init(maximum: Int) { self.maximum = maximum }
  func shouldStop() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if inspected >= maximum {
      complete = false
      return true
    }
    inspected += 1
    return false
  }
  func append(_ record: CalendarEventRecord) {
    lock.lock()
    defer { lock.unlock() }
    records.append(record)
  }
  func markIncomplete() {
    lock.lock()
    defer { lock.unlock() }
    complete = false
  }
  func snapshot(calendarIDs: [String]) -> CalendarScan {
    lock.lock()
    defer { lock.unlock() }
    return .init(records: records, calendarIDs: calendarIDs, complete: complete)
  }
}
