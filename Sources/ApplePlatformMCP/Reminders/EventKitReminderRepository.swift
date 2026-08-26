import EventKit
import Foundation

/// Keeps EventKit's storage-specific empty-value behavior out of the MCP
/// domain. In particular, a cleared `EKReminder.notes` can read back as an
/// empty string even when the write used `nil`.
enum ReminderEventKitValueNormalizer {
  static func notes(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}

/// The only type in the Reminders module that touches EventKit objects.
public actor EventKitReminderRepository: ReminderRepository {
  private let eventStore: EKEventStore

  public init() {
    eventStore = EKEventStore()
  }

  public func authorizationStatus() async -> ReminderAuthorizationStatus {
    Self.authorizationStatus()
  }

  public static func currentAuthorizationStatus() -> ReminderAuthorizationStatus {
    authorizationStatus()
  }

  public func requestFullAccess() async throws -> ReminderAuthorizationStatus {
    let current = Self.authorizationStatus()
    switch current {
    case .fullAccess:
      return current
    case .denied:
      throw ReminderError.permissionDenied
    case .restricted:
      throw ReminderError.permissionRestricted
    case .writeOnly:
      throw ReminderError.permissionWriteOnly
    case .notDetermined:
      break
    case .unavailable:
      throw ReminderError.eventStoreUnavailable
    }

    let granted: Bool
    if #available(macOS 14.0, *) {
      granted = try await withCheckedThrowingContinuation { continuation in
        eventStore.requestFullAccessToReminders { granted, error in
          if error != nil {
            continuation.resume(throwing: ReminderError.permissionDenied)
          } else {
            continuation.resume(returning: granted)
          }
        }
      }
    } else {
      // macOS 13 has the pre-macOS-14 EventKit permission API. Its authorized
      // raw value is normalized to fullAccess above; no read is attempted here.
      granted = try await withCheckedThrowingContinuation { continuation in
        eventStore.requestAccess(to: .reminder) { granted, error in
          if error != nil {
            continuation.resume(throwing: ReminderError.permissionDenied)
          } else {
            continuation.resume(returning: granted)
          }
        }
      }
    }

    // Apple documents reset() when an event store was touched before the
    // prompt. Calling it after every successful grant also gives the next
    // read a fresh view without relying on an EventKit notification race.
    eventStore.reset()
    guard granted else {
      throw Self.permissionError(for: Self.authorizationStatus())
    }

    let updated = Self.authorizationStatus()
    guard updated == .fullAccess else {
      throw Self.permissionError(for: updated)
    }
    return updated
  }

  public func listLists() async throws -> [ReminderList] {
    try requireReadAccess()
    return eventStore.calendars(for: .reminder).compactMap(makeList)
  }

  public func listReminders(listID: ReminderListReference) async throws -> [ReminderItem] {
    try requireReadAccess()
    let calendar = try resolveList(listID)

    let predicate = eventStore.predicateForReminders(in: [calendar])
    return try await fetchReminderItems(
      matching: predicate,
      expectedCalendarIdentifier: calendar.calendarIdentifier,
      listID: ReminderReferenceCodec.list(
        calendarIdentifier: calendar.calendarIdentifier,
        sourceIdentifier: calendar.source?.sourceIdentifier
      )
    )
  }

  public func getReminder(id: ReminderReference) async throws -> ReminderItem {
    try requireReadAccess()
    let reminder = try resolveReminder(id)
    guard let calendar = reminder.calendar else { throw ReminderError.reminderNotFound }

    let listID = ReminderReferenceCodec.list(
      calendarIdentifier: calendar.calendarIdentifier,
      sourceIdentifier: calendar.source?.sourceIdentifier
    )
    return try Self.makeItem(
      reminder,
      expectedCalendarIdentifier: calendar.calendarIdentifier,
      listID: listID
    )
  }

  public func createReminder(_ request: ReminderCreateRequest) async throws -> ReminderItem {
    try requireReadAccess()
    let calendar = try resolveWritableList(request.listID)
    let reminder = EKReminder(eventStore: eventStore)
    reminder.calendar = calendar
    reminder.title = request.title
    reminder.notes = request.notes
    reminder.priority = request.priority
    reminder.dueDateComponents = try request.due?.validatedDateComponents()

    do {
      try eventStore.save(reminder, commit: true)
    } catch {
      throw Self.writeError(error)
    }

    let savedReference = try reference(for: reminder)
    eventStore.reset()
    return try await getReminder(id: savedReference)
  }

  public func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderItem {
    try requireReadAccess()
    let reminder = try resolveReminder(request.id)
    guard let currentCalendar = reminder.calendar else {
      throw ReminderError.reminderNotFound
    }
    guard currentCalendar.allowsContentModifications else {
      throw ReminderError.listNotWritable
    }

    switch request.listID {
    case .unchanged:
      break
    case .set(let listID):
      reminder.calendar = try resolveWritableList(listID)
    case .clear:
      throw ReminderError.invalidInput("list_id cannot be cleared")
    }
    switch request.title {
    case .unchanged:
      break
    case .set(let title):
      reminder.title = title
    case .clear:
      throw ReminderError.invalidInput("title cannot be cleared")
    }
    switch request.notes {
    case .unchanged:
      break
    case .set(let notes):
      reminder.notes = notes
    case .clear:
      reminder.notes = nil
    }
    switch request.priority {
    case .unchanged:
      break
    case .set(let priority):
      reminder.priority = priority
    case .clear:
      throw ReminderError.invalidInput("priority cannot be cleared")
    }

    do {
      try eventStore.save(reminder, commit: true)
    } catch {
      throw Self.writeError(error)
    }

    let savedReference = try reference(for: reminder)
    eventStore.reset()
    return try await getReminder(id: savedReference)
  }

  public func completeReminder(id: ReminderReference) async throws -> ReminderItem {
    try requireReadAccess()
    let reminder = try resolveReminder(id)
    guard let calendar = reminder.calendar, calendar.allowsContentModifications else {
      throw ReminderError.listNotWritable
    }

    if !reminder.isCompleted {
      reminder.isCompleted = true
      do {
        try eventStore.save(reminder, commit: true)
      } catch {
        throw Self.writeError(error)
      }
      let savedReference = try reference(for: reminder)
      eventStore.reset()
      return try await getReminder(id: savedReference)
    }

    return try await getReminder(id: try reference(for: reminder))
  }

  public func deleteReminder(id: ReminderReference) async throws -> ReminderDeleteResult {
    try requireReadAccess()
    let reminder = try resolveReminder(id)
    guard let calendar = reminder.calendar, calendar.allowsContentModifications else {
      throw ReminderError.listNotWritable
    }

    do {
      try eventStore.remove(reminder, commit: true)
    } catch {
      throw Self.writeError(error)
    }
    eventStore.reset()
    return ReminderDeleteResult(id: id, deleted: true)
  }

  public func createList(_ request: ReminderListCreateRequest) async throws -> ReminderList {
    try requireReadAccess()
    let sourceList = try resolveWritableList(request.sourceListID)
    guard let source = sourceList.source else {
      throw ReminderError.writeFailed
    }

    let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
    calendar.source = source
    calendar.title = request.name
    do {
      try eventStore.saveCalendar(calendar, commit: true)
    } catch {
      throw Self.writeError(error)
    }

    let savedReference = try listReference(for: calendar)
    eventStore.reset()
    let saved = try resolveList(savedReference)
    guard let result = makeList(saved) else { throw ReminderError.writeFailed }
    return result
  }

  public func updateList(_ request: ReminderListUpdateRequest) async throws -> ReminderList {
    try requireReadAccess()
    let calendar = try resolveMutableList(request.id)
    calendar.title = request.name
    do {
      try eventStore.saveCalendar(calendar, commit: true)
    } catch {
      throw Self.writeError(error)
    }

    let savedReference = try listReference(for: calendar)
    eventStore.reset()
    let saved = try resolveList(savedReference)
    guard let result = makeList(saved) else { throw ReminderError.writeFailed }
    return result
  }

  public func deleteList(id: ReminderListReference) async throws -> ReminderListDeleteResult {
    try requireReadAccess()
    let calendar = try resolveMutableList(id)
    let predicate = eventStore.predicateForReminders(in: [calendar])
    let reminderCount = try await fetchReminderCount(matching: predicate)
    guard reminderCount == 0 else { throw ReminderError.listNotEmpty }

    do {
      try eventStore.removeCalendar(calendar, commit: true)
    } catch {
      throw Self.writeError(error)
    }
    eventStore.reset()
    return ReminderListDeleteResult(id: id, deleted: true, reminderCount: reminderCount)
  }

  private static func authorizationStatus() -> ReminderAuthorizationStatus {
    ReminderAuthorizationStatus.normalized(
      eventKitRawValue: EKEventStore.authorizationStatus(for: .reminder).rawValue
    )
  }

  private static func permissionError(
    for status: ReminderAuthorizationStatus
  ) -> ReminderError {
    switch status {
    case .notDetermined: return .permissionRequired
    case .restricted: return .permissionRestricted
    case .denied: return .permissionDenied
    case .writeOnly: return .permissionWriteOnly
    case .fullAccess: return .unknown
    case .unavailable: return .eventStoreUnavailable
    }
  }

  private func requireReadAccess() throws {
    switch Self.authorizationStatus() {
    case .fullAccess:
      return
    case .notDetermined:
      throw ReminderError.permissionRequired
    case .denied:
      throw ReminderError.permissionDenied
    case .restricted:
      throw ReminderError.permissionRestricted
    case .writeOnly:
      throw ReminderError.permissionWriteOnly
    case .unavailable:
      throw ReminderError.eventStoreUnavailable
    }
  }

  private func resolveList(_ id: ReminderListReference) throws -> EKCalendar {
    guard
      let anchors = ReminderReferenceCodec.decodeList(id),
      let calendar = eventStore.calendar(withIdentifier: anchors.calendarIdentifier),
      calendar.allowedEntityTypes.contains(.reminder),
      anchors.sourceIdentifier == nil
        || calendar.source?.sourceIdentifier == anchors.sourceIdentifier
    else {
      throw ReminderError.listNotFound
    }
    return calendar
  }

  private func resolveWritableList(_ id: ReminderListReference) throws -> EKCalendar {
    let calendar = try resolveList(id)
    guard calendar.allowsContentModifications else {
      throw ReminderError.listNotWritable
    }
    return calendar
  }

  private func resolveMutableList(_ id: ReminderListReference) throws -> EKCalendar {
    let calendar = try resolveWritableList(id)
    guard !calendar.isImmutable else {
      throw ReminderError.listNotWritable
    }
    return calendar
  }

  /// Resolves only the direct private primary anchor encoded in the opaque
  /// reference and validates all available anchors. There is intentionally no
  /// external-identifier, title, date, or list-search fallback for writes.
  private func resolveReminder(_ id: ReminderReference) throws -> EKReminder {
    guard
      let anchors = ReminderReferenceCodec.decodeReminder(id),
      let calendarItemIdentifier = anchors.calendarItemIdentifier,
      let reminder = eventStore.calendarItem(withIdentifier: calendarItemIdentifier) as? EKReminder,
      let calendar = reminder.calendar,
      calendar.allowedEntityTypes.contains(.reminder),
      calendar.calendarIdentifier == anchors.calendarIdentifier,
      reminder.calendarItemIdentifier == calendarItemIdentifier,
      anchors.sourceIdentifier == nil
        || calendar.source?.sourceIdentifier == anchors.sourceIdentifier,
      anchors.calendarItemExternalIdentifier == nil
        || reminder.calendarItemExternalIdentifier == anchors.calendarItemExternalIdentifier
    else {
      throw ReminderError.reminderNotFound
    }
    return reminder
  }

  private func reference(for reminder: EKReminder) throws -> ReminderReference {
    guard let calendar = reminder.calendar, !reminder.calendarItemIdentifier.isEmpty else {
      throw ReminderError.writeFailed
    }
    return ReminderReferenceCodec.reminder(
      calendarIdentifier: calendar.calendarIdentifier,
      calendarItemIdentifier: reminder.calendarItemIdentifier,
      calendarItemExternalIdentifier: reminder.calendarItemExternalIdentifier,
      sourceIdentifier: calendar.source?.sourceIdentifier
    )
  }

  private func listReference(for calendar: EKCalendar) throws -> ReminderListReference {
    guard !calendar.calendarIdentifier.isEmpty else {
      throw ReminderError.writeFailed
    }
    return ReminderReferenceCodec.list(
      calendarIdentifier: calendar.calendarIdentifier,
      sourceIdentifier: calendar.source?.sourceIdentifier
    )
  }

  private static func writeError(_ _: Error) -> ReminderError {
    // EventKit NSError details can include account- and item-specific data.
    // The MCP boundary receives a stable normalized error only.
    .writeFailed
  }

  private func makeList(_ calendar: EKCalendar) -> ReminderList? {
    let identifier = calendar.calendarIdentifier
    let title = calendar.title
    guard !identifier.isEmpty, !title.isEmpty else { return nil }

    return ReminderList(
      id: ReminderReferenceCodec.list(
        calendarIdentifier: identifier,
        sourceIdentifier: calendar.source?.sourceIdentifier
      ),
      name: title,
      sourceName: calendar.source?.title,
      capabilities: ReminderListCapabilities(
        canRead: true,
        canWrite: calendar.allowsContentModifications
      )
    )
  }

  private func fetchReminderItems(
    matching predicate: NSPredicate,
    expectedCalendarIdentifier: String,
    listID: ReminderListReference
  ) async throws -> [ReminderItem] {
    try await withCheckedThrowingContinuation { continuation in
      _ = eventStore.fetchReminders(matching: predicate) { reminders in
        do {
          let items = try (reminders ?? []).map { reminder in
            try Self.makeItem(
              reminder,
              expectedCalendarIdentifier: expectedCalendarIdentifier,
              listID: listID
            )
          }
          continuation.resume(returning: items)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func fetchReminderCount(matching predicate: NSPredicate) async throws -> Int {
    try await withCheckedThrowingContinuation { continuation in
      _ = eventStore.fetchReminders(matching: predicate) { reminders in
        continuation.resume(returning: reminders?.count ?? 0)
      }
    }
  }

  private static func makeItem(
    _ reminder: EKReminder,
    expectedCalendarIdentifier: String,
    listID: ReminderListReference
  ) throws -> ReminderItem {
    guard
      let calendar = reminder.calendar,
      calendar.calendarIdentifier == expectedCalendarIdentifier,
      !reminder.calendarItemIdentifier.isEmpty
    else {
      throw ReminderError.invalidReference
    }

    let reference = ReminderReferenceCodec.reminder(
      calendarIdentifier: calendar.calendarIdentifier,
      calendarItemIdentifier: reminder.calendarItemIdentifier,
      calendarItemExternalIdentifier: reminder.calendarItemExternalIdentifier,
      sourceIdentifier: calendar.source?.sourceIdentifier
    )

    return ReminderItem(
      id: reference,
      listID: listID,
      title: reminder.title,
      notes: ReminderEventKitValueNormalizer.notes(reminder.notes),
      priority: Int(reminder.priority),
      completed: reminder.isCompleted,
      completionDate: reminder.completionDate,
      due: try makeDue(from: reminder.dueDateComponents),
      recurrence: try makeRecurrence(from: reminder.recurrenceRules)
    )
  }

  private static func makeDue(from components: DateComponents?) throws -> ReminderDue? {
    guard let components else { return nil }
    guard let year = components.year, let month = components.month, let day = components.day else {
      throw ReminderError.unsupportedDue
    }

    let date = String(format: "%04d-%02d-%02d", year, month, day)
    guard ReminderDateValueParser.dateOnly(date, timeZone: TimeZone(secondsFromGMT: 0)!) != nil
    else {
      throw ReminderError.unsupportedDue
    }

    let hasAnyTimeComponent =
      components.hour != nil
      || components.minute != nil
      || components.second != nil
    if !hasAnyTimeComponent {
      return .allDay(date: date)
    }

    let second = components.second ?? 0
    guard let hour = components.hour, let minute = components.minute else {
      throw ReminderError.unsupportedDue
    }

    let time = String(format: "%02d:%02d:%02d", hour, minute, second)
    guard let timeZone = components.timeZone else {
      throw ReminderError.unsupportedDue
    }
    guard
      ReminderDateValueParser.timed(
        date: date,
        time: time,
        timeZone: timeZone
      ) != nil
    else {
      throw ReminderError.unsupportedDue
    }
    return .timed(
      date: date,
      time: time,
      timeZone: timeZone.identifier
    )
  }

  private static func makeRecurrence(from rules: [EKRecurrenceRule]?) throws -> ReminderRecurrence?
  {
    guard let rules, !rules.isEmpty else { return nil }
    guard rules.count == 1, let rule = rules.first, rule.interval > 0 else {
      throw ReminderError.unsupportedRecurrence
    }

    let frequency: ReminderRecurrence.Frequency
    switch rule.frequency.rawValue {
    case 0: frequency = .daily
    case 1: frequency = .weekly
    case 2: frequency = .monthly
    case 3: frequency = .yearly
    default: throw ReminderError.unsupportedRecurrence
    }

    guard (rule.daysOfTheYear ?? []).isEmpty,
      (rule.weeksOfTheYear ?? []).isEmpty,
      (rule.setPositions ?? []).isEmpty
    else {
      throw ReminderError.unsupportedRecurrence
    }

    let weekdays = try (rule.daysOfTheWeek ?? []).map { day -> ReminderRecurrenceDay in
      guard let weekday = ReminderWeekday(eventKitRawValue: day.dayOfTheWeek.rawValue) else {
        throw ReminderError.unsupportedRecurrence
      }
      return ReminderRecurrenceDay(
        weekday: weekday,
        weekNumber: day.weekNumber == 0 ? nil : day.weekNumber
      )
    }

    let firstDayOfWeek: ReminderWeekday?
    if rule.firstDayOfTheWeek == 0 {
      firstDayOfWeek = nil
    } else {
      guard let value = ReminderWeekday(eventKitRawValue: rule.firstDayOfTheWeek) else {
        throw ReminderError.unsupportedRecurrence
      }
      firstDayOfWeek = value
    }

    let endDate = rule.recurrenceEnd?.endDate
    let rawOccurrenceCount = rule.recurrenceEnd?.occurrenceCount ?? 0
    guard !(endDate != nil && rawOccurrenceCount > 0) else {
      throw ReminderError.unsupportedRecurrence
    }

    return ReminderRecurrence(
      frequency: frequency,
      interval: Int(rule.interval),
      weekdays: weekdays,
      daysOfMonth: (rule.daysOfTheMonth ?? []).map(\.intValue),
      monthsOfYear: (rule.monthsOfTheYear ?? []).map(\.intValue),
      firstDayOfWeek: firstDayOfWeek,
      endDate: endDate,
      occurrenceCount: rawOccurrenceCount > 0 ? rawOccurrenceCount : nil
    )
  }
}

extension ReminderWeekday {
  fileprivate init?(eventKitRawValue: Int) {
    switch eventKitRawValue {
    case 1: self = .sunday
    case 2: self = .monday
    case 3: self = .tuesday
    case 4: self = .wednesday
    case 5: self = .thursday
    case 6: self = .friday
    case 7: self = .saturday
    default: return nil
    }
  }
}
