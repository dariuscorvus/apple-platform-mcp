import Foundation

public enum CalendarAccess: String, Codable, Sendable {
  case notDetermined = "not_determined"
  case restricted, denied
  case writeOnly = "write_only"
  case fullAccess = "full_access"
  case unavailable
  public static func normalized(_ raw: Int) -> Self {
    switch raw {
    case 0: .notDetermined
    case 1: .restricted
    case 2: .denied
    case 3: .fullAccess
    case 4: .writeOnly
    default: .unavailable
    }
  }
}

public struct CalendarError: Error, LocalizedError, Equatable, Sendable {
  public let code: String
  public init(_ code: String) { self.code = code }
  public var errorDescription: String? {
    switch code {
    case "calendarPermissionRequired":
      return "Run doctor --request-calendar from the actual signed app host."
    case "calendarPermissionDenied": return "Calendar Full Access is denied or restricted."
    case "calendarPermissionWriteOnly":
      return "Calendar Full Access is required; write-only access is insufficient."
    case "calendarPolicyDenied":
      return "Calendar creation is disabled or this calendar is not explicitly allowed."
    case "calendarNotWritable": return "The selected calendar does not allow event creation."
    case "calendarNotFound": return "The selected calendar no longer exists. Refresh its reference."
    case "calendarEventNotFound":
      return "The selected occurrence no longer matches its reference. Refresh the search."
    case "calendarAmbiguousReference": return "The event reference matches multiple occurrences."
    case "calendarInvalidReference":
      return "Use the exact versioned Calendar reference returned by a discovery tool."
    case "calendarInvalidInput":
      return "Calendar arguments have an invalid type, size, date, offset or time zone."
    case "calendarJournalUnavailable":
      return "The Calendar journal is unavailable; no new write is permitted."
    case "calendarIdempotencyConflict":
      return "The idempotency key belongs to a different normalized request."
    case "calendarCreationOutcomeUnknown":
      return
        "Creation may have completed. Inspect the outcome and calendar before any new key; do not retry the write."
    case "calendarTraversalLimit":
      return "The exact occurrence could not be resolved within the scan limit."
    default: return "Calendar operation failed without exposing backend details."
    }
  }
}

public enum CalendarMutationMode: String, Codable, Sendable {
  case denied, allowed
  case confirmationRequired = "confirmation_required"
}
public struct CalendarPolicy: Sendable {
  public let mode: CalendarMutationMode
  public let allowedWriteIDs: Set<String>
  public init(mode: CalendarMutationMode = .denied, allowedWriteIDs: Set<String> = []) {
    self.mode = mode
    self.allowedWriteIDs = allowedWriteIDs
  }
  public func allowsWrite(_ id: String) -> Bool { mode == .allowed && allowedWriteIDs.contains(id) }
  public func validateWrite(_ id: String) throws {
    guard allowsWrite(id) else { throw CalendarError("calendarPolicyDenied") }
  }
}

/// Date-only intervals have an exclusive end and calendar-day duration, never a fixed 86400-second assumption.
public struct CalendarTimeRange: Codable, Sendable, Equatable {
  public let start: String
  public let end: String
  public let timeZone: String
  public let allDay: Bool
  public init(start: String, end: String, timeZone: String, allDay: Bool = false) {
    self.start = start
    self.end = end
    self.timeZone = timeZone
    self.allDay = allDay
  }
  enum CodingKeys: String, CodingKey {
    case start, end
    case timeZone = "time_zone"
    case allDay = "all_day"
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      start: try c.decode(String.self, forKey: .start),
      end: try c.decode(String.self, forKey: .end),
      timeZone: try c.decode(String.self, forKey: .timeZone),
      allDay: try c.decodeIfPresent(Bool.self, forKey: .allDay) ?? false)
  }
  public func validated() throws -> CalendarWindow {
    guard TimeZone.knownTimeZoneIdentifiers.contains(timeZone) || timeZone == "UTC",
      let zone = TimeZone(identifier: timeZone)
    else { throw CalendarError("calendarInvalidInput") }
    let a: Date?
    let b: Date?
    if allDay {
      a = Self.day(start, zone)
      b = Self.day(end, zone)
    } else {
      a = Self.instant(start, zone)
      b = Self.instant(end, zone)
    }
    guard let a, let b, b > a else { throw CalendarError("calendarInvalidInput") }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    guard let maximum = calendar.date(byAdding: .day, value: 366, to: a), b <= maximum else {
      throw CalendarError("calendarInvalidInput")
    }
    return CalendarWindow(start: a, end: b, timeZone: zone)
  }
  public func canonical() throws -> Self {
    let w = try validated()
    return Self(
      start: allDay ? Self.dateString(w.start, w.timeZone) : Self.timestamp(w.start, w.timeZone),
      end: allDay ? Self.dateString(w.end, w.timeZone) : Self.timestamp(w.end, w.timeZone),
      timeZone: w.timeZone.identifier, allDay: allDay)
  }
  static func day(_ text: String, _ zone: TimeZone) -> Date? {
    let parts = text.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
      text.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || $0 == "-" }),
      let y = Int(parts[0]), y >= 1, let m = Int(parts[1]), let d = Int(parts[2])
    else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    guard let date = calendar.date(from: DateComponents(year: y, month: m, day: d)),
      dateString(date, zone) == text
    else { return nil }
    return date
  }
  static func instant(_ text: String, _ zone: TimeZone) -> Date? {
    guard
      text.range(
        of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?(Z|[+-]\d{2}:\d{2})$"#,
        options: .regularExpression) != nil
    else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date =
      formatter.date(from: text)
      ?? {
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
      }()
    guard let date else { return nil }
    let local = DateFormatter()
    local.locale = Locale(identifier: "en_US_POSIX")
    local.calendar = Calendar(identifier: .gregorian)
    local.timeZone = zone
    local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    guard local.string(from: date) == String(text.prefix(19)) else { return nil }
    let offset: Int
    if text.hasSuffix("Z") {
      offset = 0
    } else {
      let tail = Array(text.suffix(6))
      guard let h = Int(String(tail[1...2])), let m = Int(String(tail[4...5])), h <= 23, m <= 59
      else { return nil }
      offset = (tail[0] == "-" ? -1 : 1) * (h * 3600 + m * 60)
    }
    return zone.secondsFromGMT(for: date) == offset ? date : nil
  }
  static func timestamp(_ date: Date, _ zone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = zone
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
  }
  static func dateString(_ date: Date, _ zone: TimeZone) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = zone
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
  }
}
public struct CalendarWindow: Sendable {
  public let start: Date
  public let end: Date
  public let timeZone: TimeZone
  public func overlaps(start: Date, end: Date) -> Bool { start < self.end && end > self.start }
}

struct CalendarAnchors: Codable, Sendable, Equatable {
  let version: Int
  let kind: String
  let source: String
  let calendar: String
  let event: String?
  let occurrence: String?
  let start: String?
  let end: String?
}
enum CalendarReferenceCodec {
  static func calendar(source: String, calendar: String) throws -> String {
    try encode(
      CalendarAnchors(
        version: 1, kind: "calendar", source: source, calendar: calendar, event: nil,
        occurrence: nil, start: nil, end: nil))
  }
  static func event(
    source: String, calendar: String, event: String, occurrence: Date?, start: Date, end: Date
  ) throws -> String {
    try encode(
      CalendarAnchors(
        version: 1, kind: "event", source: source, calendar: calendar, event: event,
        occurrence: occurrence.map { CalendarTimeRange.timestamp($0) },
        start: CalendarTimeRange.timestamp(start), end: CalendarTimeRange.timestamp(end)))
  }
  static func encode(_ value: CalendarAnchors) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return "cal_v1_" + (try encoder.encode(value)).base64EncodedString()
  }
  static func decode(_ value: String, kind: String) throws -> CalendarAnchors {
    guard value.hasPrefix("cal_v1_"), value.utf8.count <= 16_384,
      let data = Data(base64Encoded: String(value.dropFirst(7))),
      let p = try? JSONDecoder().decode(CalendarAnchors.self, from: data),
      p.version == 1, p.kind == kind, !p.source.isEmpty, !p.calendar.isEmpty
    else { throw CalendarError("calendarInvalidReference") }
    if kind == "event" {
      guard p.event?.isEmpty == false, let a = p.start, let b = p.end,
        let start = CalendarTimeRange.instant(a, TimeZone(secondsFromGMT: 0)!),
        let end = CalendarTimeRange.instant(b, TimeZone(secondsFromGMT: 0)!), end > start,
        p.occurrence == nil
          || CalendarTimeRange.instant(p.occurrence!, TimeZone(secondsFromGMT: 0)!) != nil
      else { throw CalendarError("calendarInvalidReference") }
    } else if p.event != nil || p.occurrence != nil || p.start != nil || p.end != nil {
      throw CalendarError("calendarInvalidReference")
    }
    return p
  }
}

public struct CalendarDescriptor: Codable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let source: String
  public let canWrite: Bool
  public var policyAllowsWrite: Bool
  enum CodingKeys: String, CodingKey {
    case id, name, source
    case canWrite = "can_write"
    case policyAllowsWrite = "policy_allows_write"
  }
  public init(
    id: String, name: String, source: String, canWrite: Bool, policyAllowsWrite: Bool = false
  ) {
    self.id = id
    self.name = name
    self.source = source
    self.canWrite = canWrite
    self.policyAllowsWrite = policyAllowsWrite
  }
}
public struct CalendarEvent: Codable, Sendable, Equatable {
  public let id: String
  public let calendarID: String
  public let title: String
  public let time: CalendarTimeRange
  public let timeZoneSource: String
  public let location: String?
  public var notes: String?
  public let recurring: Bool
  public let detached: Bool
  public let status: String
  public let availability: String
  public var truncated: Bool
  enum CodingKeys: String, CodingKey {
    case id, title, time, location, notes, recurring, detached, status, availability, truncated
    case calendarID = "calendar_id"
    case timeZoneSource = "time_zone_source"
  }
  public init(
    id: String, calendarID: String, title: String, time: CalendarTimeRange,
    timeZoneSource: String = "event",
    location: String? = nil, notes: String? = nil, recurring: Bool = false, detached: Bool = false,
    status: String = "confirmed", availability: String = "busy", truncated: Bool = false
  ) {
    self.id = id
    self.calendarID = calendarID
    self.title = title
    self.time = time
    self.timeZoneSource = timeZoneSource
    self.location = location
    self.notes = notes
    self.recurring = recurring
    self.detached = detached
    self.status = status
    self.availability = availability
    self.truncated = truncated
  }
}
public struct CalendarEventRecord: Sendable {
  public let event: CalendarEvent
  public let start: Date
  public let end: Date
  public init(event: CalendarEvent, start: Date, end: Date) {
    self.event = event
    self.start = start
    self.end = end
  }
}
public struct CalendarScan: Sendable {
  public let records: [CalendarEventRecord]
  public let calendarIDs: [String]
  public let complete: Bool
  public init(records: [CalendarEventRecord], calendarIDs: [String], complete: Bool) {
    self.records = records
    self.calendarIDs = calendarIDs
    self.complete = complete
  }
}
public struct CalendarSearchResult: Codable, Sendable {
  public let items: [CalendarEvent]
  public let calendarIDs: [String]
  public let truncated: Bool
  enum CodingKeys: String, CodingKey {
    case items, truncated
    case calendarIDs = "calendar_ids_examined"
  }
}
public struct CalendarConflictResult: Codable, Sendable {
  public let status: String
  public let conflicts: [CalendarEvent]
  public let count: Int
  public let calendarIDs: [String]
  public let truncated: Bool
  enum CodingKeys: String, CodingKey {
    case status, conflicts, count, truncated
    case calendarIDs = "calendar_ids_examined"
  }
}
public struct CalendarCreateRequest: Codable, Sendable, Equatable {
  public let calendarID: String
  public let title: String
  public let time: CalendarTimeRange
  public let location: String?
  public let notes: String?
  enum CodingKeys: String, CodingKey {
    case calendarID = "calendar_id"
    case title, time, location, notes
  }
  public init(
    calendarID: String, title: String, time: CalendarTimeRange, location: String? = nil,
    notes: String? = nil
  ) {
    self.calendarID = calendarID
    self.title = title
    self.time = time
    self.location = location
    self.notes = notes
  }
}
/// Cached create results deliberately exclude event text and other people's conflicts.
public struct CalendarCreationResult: Codable, Sendable, Equatable {
  public let eventID: String
  public let calendarID: String
  public let conflictStatus: String
  public let conflictCount: Int
  public let calendarIDsExamined: [String]
  public let warnings: [String]
  enum CodingKeys: String, CodingKey {
    case eventID = "event_id"
    case calendarID = "calendar_id"
    case conflictStatus = "conflict_status"
    case conflictCount = "conflict_count"
    case calendarIDsExamined = "calendar_ids_examined"
    case warnings
  }
}
public struct CalendarCreationOutcome: Codable, Sendable {
  public let status: String
  public let result: CalendarCreationResult?
}
public protocol CalendarRepository: Sendable {
  func authorizationStatus() async -> CalendarAccess
  func requestFullAccess() async throws -> CalendarAccess
  func listCalendars() async throws -> [CalendarDescriptor]
  func scan(window: CalendarWindow, calendarIDs: [String]?, maximum: Int) async throws
    -> CalendarScan
  func getEvent(id: String) async throws -> CalendarEventRecord
  func writableCalendar(id: String) async throws -> CalendarDescriptor
  func createEvent(_ request: CalendarCreateRequest) async throws -> CalendarEventRecord
}

/// Resolves the exact occurrence snapshot; never falls back to the first series event.
enum CalendarOccurrenceResolver {
  static func resolve(_ anchors: CalendarAnchors, scan: CalendarScan) throws -> CalendarEventRecord
  {
    guard scan.complete else { throw CalendarError("calendarTraversalLimit") }
    let matches = scan.records.filter {
      (try? CalendarReferenceCodec.decode($0.event.id, kind: "event")) == anchors
    }
    guard matches.count <= 1 else { throw CalendarError("calendarAmbiguousReference") }
    guard let match = matches.first else { throw CalendarError("calendarEventNotFound") }
    return match
  }
}
