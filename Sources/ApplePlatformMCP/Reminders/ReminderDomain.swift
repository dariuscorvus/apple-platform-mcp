import Foundation

public enum ReminderAuthorizationStatus: String, Codable, Equatable, Sendable {
  case notDetermined = "not_determined"
  case restricted
  case denied
  case writeOnly = "write_only"
  case fullAccess = "full_access"
  case unavailable

  /// EventKit uses the same raw values for the legacy `authorized` state and
  /// the current `fullAccess` state. Keeping this conversion free of
  /// EventKit types makes the permission contract testable without prompting.
  public static func normalized(eventKitRawValue: Int) -> Self {
    switch eventKitRawValue {
    case 0: return .notDetermined
    case 1: return .restricted
    case 2: return .denied
    case 3: return .fullAccess
    case 4: return .writeOnly
    default: return .unavailable
    }
  }

  public var allowsRead: Bool {
    self == .fullAccess
  }
}

public enum ReminderPermissionRequirements {
  public static let fullAccessUsageDescriptionKey = "NSRemindersFullAccessUsageDescription"
  public static let legacyUsageDescriptionKey = "NSRemindersUsageDescription"
}

public struct ReminderReference: Codable, Hashable, Sendable {
  public let version: Int
  public let opaqueValue: String

  public init(version: Int = 1, opaqueValue: String) {
    self.version = version
    self.opaqueValue = opaqueValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(opaqueValue: try container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(opaqueValue)
  }
}

public struct ReminderListReference: Codable, Hashable, Sendable {
  public let version: Int
  public let opaqueValue: String

  public init(version: Int = 1, opaqueValue: String) {
    self.version = version
    self.opaqueValue = opaqueValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(opaqueValue: try container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(opaqueValue)
  }
}

/// The adapter's private reference payload. It is deliberately not public:
/// Apple identifiers are only inputs to the adapter's resolver and never part
/// of the MCP domain contract.
struct ReminderReferenceAnchors: Codable {
  let version: Int
  let kind: String
  let calendarIdentifier: String
  let calendarItemIdentifier: String?
  let calendarItemExternalIdentifier: String?
  let sourceIdentifier: String?
}

public enum ReminderReferenceCodec {
  static func list(
    calendarIdentifier: String,
    sourceIdentifier: String? = nil
  ) -> ReminderListReference {
    ReminderListReference(
      opaqueValue: encode(
        ReminderReferenceAnchors(
          version: 1,
          kind: "reminder_list",
          calendarIdentifier: calendarIdentifier,
          calendarItemIdentifier: nil,
          calendarItemExternalIdentifier: nil,
          sourceIdentifier: sourceIdentifier
        )))
  }

  static func reminder(
    calendarIdentifier: String,
    calendarItemIdentifier: String,
    calendarItemExternalIdentifier: String? = nil,
    sourceIdentifier: String? = nil
  ) -> ReminderReference {
    ReminderReference(
      opaqueValue: encode(
        ReminderReferenceAnchors(
          version: 1,
          kind: "reminder",
          calendarIdentifier: calendarIdentifier,
          calendarItemIdentifier: calendarItemIdentifier,
          calendarItemExternalIdentifier: calendarItemExternalIdentifier,
          sourceIdentifier: sourceIdentifier
        )))
  }

  public static func isValid(_ reference: ReminderListReference) -> Bool {
    guard reference.version == 1, let anchors = decode(reference.opaqueValue) else {
      return false
    }
    return anchors.version == 1
      && anchors.kind == "reminder_list"
      && !anchors.calendarIdentifier.isEmpty
      && anchors.calendarItemIdentifier == nil
  }

  public static func isValid(_ reference: ReminderReference) -> Bool {
    guard reference.version == 1, let anchors = decode(reference.opaqueValue) else {
      return false
    }
    return anchors.version == 1
      && anchors.kind == "reminder"
      && !anchors.calendarIdentifier.isEmpty
      && anchors.calendarItemIdentifier?.isEmpty == false
  }

  static func decodeList(_ reference: ReminderListReference) -> ReminderReferenceAnchors? {
    guard reference.version == 1, let anchors = decode(reference.opaqueValue) else {
      return nil
    }
    guard anchors.version == 1, anchors.kind == "reminder_list" else { return nil }
    return anchors
  }

  static func decodeReminder(_ reference: ReminderReference) -> ReminderReferenceAnchors? {
    guard reference.version == 1, let anchors = decode(reference.opaqueValue) else {
      return nil
    }
    guard
      anchors.version == 1,
      anchors.kind == "reminder",
      !anchors.calendarIdentifier.isEmpty,
      anchors.calendarItemIdentifier?.isEmpty == false
    else {
      return nil
    }
    return anchors
  }

  private static func encode(_ anchors: ReminderReferenceAnchors) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(anchors) else { return "rr1_invalid" }

    return "rr1_"
      + data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func decode(_ value: String) -> ReminderReferenceAnchors? {
    guard value.hasPrefix("rr1_") else { return nil }
    var encoded = String(value.dropFirst(4))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)

    guard let data = Data(base64Encoded: encoded) else { return nil }
    return try? JSONDecoder().decode(ReminderReferenceAnchors.self, from: data)
  }
}

public enum ReminderWeekday: String, Codable, Hashable, Sendable {
  case sunday
  case monday
  case tuesday
  case wednesday
  case thursday
  case friday
  case saturday
}

public struct ReminderRecurrenceDay: Codable, Hashable, Sendable {
  public let weekday: ReminderWeekday
  public let weekNumber: Int?

  public init(weekday: ReminderWeekday, weekNumber: Int? = nil) {
    self.weekday = weekday
    self.weekNumber = weekNumber
  }

  private enum CodingKeys: String, CodingKey {
    case weekday
    case weekNumber = "week_number"
  }
}

public enum ReminderDue: Codable, Hashable, Sendable {
  case allDay(date: String)
  case timed(date: String, time: String, timeZone: String?)

  private enum CodingKeys: String, CodingKey {
    case allDay = "all_day"
    case date
    case time
    case timeZone = "time_zone"
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .allDay(let date):
      try container.encode(true, forKey: .allDay)
      try container.encode(date, forKey: .date)
      try container.encodeNil(forKey: .time)
      try container.encodeNil(forKey: .timeZone)
    case .timed(let date, let time, let timeZone):
      try container.encode(false, forKey: .allDay)
      try container.encode(date, forKey: .date)
      try container.encode(time, forKey: .time)
      try container.encodeIfPresent(timeZone, forKey: .timeZone)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let date = try container.decode(String.self, forKey: .date)
    let allDay =
      try container.decodeIfPresent(Bool.self, forKey: .allDay)
      ?? !container.contains(.time)
    if allDay {
      self = .allDay(date: date)
    } else {
      self = .timed(
        date: date,
        time: try container.decode(String.self, forKey: .time),
        timeZone: try container.decodeIfPresent(String.self, forKey: .timeZone)
      )
    }
  }
}

public struct ReminderRecurrence: Codable, Hashable, Sendable {
  public enum Frequency: String, Codable, Hashable, Sendable {
    case daily
    case weekly
    case monthly
    case yearly
  }

  public let frequency: Frequency
  public let interval: Int
  public let weekdays: [ReminderRecurrenceDay]
  public let daysOfMonth: [Int]
  public let monthsOfYear: [Int]
  public let firstDayOfWeek: ReminderWeekday?
  public let endDate: Date?
  public let occurrenceCount: Int?

  public init(
    frequency: Frequency,
    interval: Int = 1,
    weekdays: [ReminderRecurrenceDay] = [],
    daysOfMonth: [Int] = [],
    monthsOfYear: [Int] = [],
    firstDayOfWeek: ReminderWeekday? = nil,
    endDate: Date? = nil,
    occurrenceCount: Int? = nil
  ) {
    self.frequency = frequency
    self.interval = interval
    self.weekdays = weekdays
    self.daysOfMonth = daysOfMonth
    self.monthsOfYear = monthsOfYear
    self.firstDayOfWeek = firstDayOfWeek
    self.endDate = endDate
    self.occurrenceCount = occurrenceCount
  }

  private enum CodingKeys: String, CodingKey {
    case frequency
    case interval
    case weekdays
    case daysOfMonth = "days_of_month"
    case monthsOfYear = "months_of_year"
    case firstDayOfWeek = "first_day_of_week"
    case endDate = "end_date"
    case occurrenceCount = "occurrence_count"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      frequency: try container.decode(Frequency.self, forKey: .frequency),
      interval: try container.decode(Int.self, forKey: .interval),
      weekdays: try container.decodeIfPresent([ReminderRecurrenceDay].self, forKey: .weekdays)
        ?? [],
      daysOfMonth: try container.decodeIfPresent([Int].self, forKey: .daysOfMonth) ?? [],
      monthsOfYear: try container.decodeIfPresent([Int].self, forKey: .monthsOfYear) ?? [],
      firstDayOfWeek: try container.decodeIfPresent(
        ReminderWeekday.self, forKey: .firstDayOfWeek),
      endDate: try ReminderDateCodec.decode(container, key: .endDate),
      occurrenceCount: try container.decodeIfPresent(Int.self, forKey: .occurrenceCount)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(frequency, forKey: .frequency)
    try container.encode(interval, forKey: .interval)
    try container.encode(weekdays, forKey: .weekdays)
    try container.encode(daysOfMonth, forKey: .daysOfMonth)
    try container.encode(monthsOfYear, forKey: .monthsOfYear)
    try container.encodeIfPresent(firstDayOfWeek, forKey: .firstDayOfWeek)
    try ReminderDateCodec.encode(endDate, into: &container, key: .endDate)
    try container.encodeIfPresent(occurrenceCount, forKey: .occurrenceCount)
  }
}

public struct ReminderListCapabilities: Codable, Hashable, Sendable {
  public let canRead: Bool
  public let canWrite: Bool

  public init(canRead: Bool = true, canWrite: Bool = false) {
    self.canRead = canRead
    self.canWrite = canWrite
  }

  private enum CodingKeys: String, CodingKey {
    case canRead = "can_read"
    case canWrite = "can_write"
  }
}

public struct ReminderList: Codable, Hashable, Sendable {
  public let id: ReminderListReference
  public let name: String
  public let sourceName: String?
  public let capabilities: ReminderListCapabilities

  public init(
    id: ReminderListReference,
    name: String,
    sourceName: String? = nil,
    capabilities: ReminderListCapabilities = .init()
  ) {
    self.id = id
    self.name = name
    self.sourceName = sourceName
    self.capabilities = capabilities
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case sourceName = "source_name"
    case capabilities
  }
}

public struct ReminderItem: Codable, Hashable, Sendable {
  public let id: ReminderReference
  public let listID: ReminderListReference
  public let title: String
  public let notes: String?
  public let priority: Int
  public let completed: Bool
  public let completionDate: Date?
  public let due: ReminderDue?
  public let recurrence: ReminderRecurrence?

  public init(
    id: ReminderReference,
    listID: ReminderListReference,
    title: String,
    notes: String? = nil,
    priority: Int = 0,
    completed: Bool,
    completionDate: Date? = nil,
    due: ReminderDue? = nil,
    recurrence: ReminderRecurrence? = nil
  ) {
    self.id = id
    self.listID = listID
    self.title = title
    self.notes = notes
    self.priority = priority
    self.completed = completed
    self.completionDate = completionDate
    self.due = due
    self.recurrence = recurrence
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case listID = "list_id"
    case title
    case notes
    case priority
    case completed
    case completionDate = "completion_date"
    case due
    case recurrence
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(ReminderReference.self, forKey: .id),
      listID: try container.decode(ReminderListReference.self, forKey: .listID),
      title: try container.decode(String.self, forKey: .title),
      notes: try container.decodeIfPresent(String.self, forKey: .notes),
      priority: try container.decode(Int.self, forKey: .priority),
      completed: try container.decode(Bool.self, forKey: .completed),
      completionDate: try ReminderDateCodec.decode(container, key: .completionDate),
      due: try container.decodeIfPresent(ReminderDue.self, forKey: .due),
      recurrence: try container.decodeIfPresent(ReminderRecurrence.self, forKey: .recurrence)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(listID, forKey: .listID)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(notes, forKey: .notes)
    try container.encode(priority, forKey: .priority)
    try container.encode(completed, forKey: .completed)
    try ReminderDateCodec.encode(completionDate, into: &container, key: .completionDate)
    try container.encodeIfPresent(due, forKey: .due)
    try container.encodeIfPresent(recurrence, forKey: .recurrence)
  }
}

/// The safe create payload for a Reminder write. Due values are represented
/// explicitly so EventKit can persist a native date rather than relying on
/// title or note text.
public struct ReminderCreateRequest: Codable, Hashable, Sendable {
  public let listID: ReminderListReference
  public let title: String
  public let notes: String?
  public let priority: Int
  public let due: ReminderDue?

  public init(
    listID: ReminderListReference,
    title: String,
    notes: String? = nil,
    priority: Int = 0,
    due: ReminderDue? = nil
  ) {
    self.listID = listID
    self.title = title
    self.notes = notes
    self.priority = priority
    self.due = due
  }

  private enum CodingKeys: String, CodingKey {
    case listID = "list_id"
    case title
    case notes
    case priority
    case due
  }
}

/// Distinguishes an omitted patch field from an explicit clear. Its serialized
/// shape is internal to the service/idempotency fingerprint; MCP arguments are
/// parsed into this value and never need to expose this representation.
public enum ReminderFieldPatch<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
  case unchanged
  case set(Value)
  case clear

  private enum CodingKeys: String, CodingKey {
    case kind
    case value
  }

  private enum Kind: String, Codable {
    case unchanged
    case set
    case clear
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .unchanged:
      self = .unchanged
    case .set:
      self = .set(try container.decode(Value.self, forKey: .value))
    case .clear:
      self = .clear
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .unchanged:
      try container.encode(Kind.unchanged, forKey: .kind)
    case .set(let value):
      try container.encode(Kind.set, forKey: .kind)
      try container.encode(value, forKey: .value)
    case .clear:
      try container.encode(Kind.clear, forKey: .kind)
    }
  }

  public var isChanged: Bool {
    self != .unchanged
  }
}

/// Patch-only update request. The absence of a field means preserve the
/// current EventKit value; `clear` is only valid for nullable fields.
public struct ReminderUpdateRequest: Codable, Hashable, Sendable {
  public let id: ReminderReference
  public let listID: ReminderFieldPatch<ReminderListReference>
  public let title: ReminderFieldPatch<String>
  public let notes: ReminderFieldPatch<String>
  public let priority: ReminderFieldPatch<Int>

  public init(
    id: ReminderReference,
    listID: ReminderFieldPatch<ReminderListReference> = .unchanged,
    title: ReminderFieldPatch<String> = .unchanged,
    notes: ReminderFieldPatch<String> = .unchanged,
    priority: ReminderFieldPatch<Int> = .unchanged
  ) {
    self.id = id
    self.listID = listID
    self.title = title
    self.notes = notes
    self.priority = priority
  }

  public var hasChanges: Bool {
    listID.isChanged || title.isChanged || notes.isChanged || priority.isChanged
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case listID = "list_id"
    case title
    case notes
    case priority
  }
}

public struct ReminderDeleteResult: Codable, Hashable, Sendable {
  public let id: ReminderReference
  public let deleted: Bool

  public init(id: ReminderReference, deleted: Bool) {
    self.id = id
    self.deleted = deleted
  }
}

/// A new Reminder list inherits its EventKit source from one explicit existing
/// list reference. The public contract never accepts a provider source ID.
public struct ReminderListCreateRequest: Codable, Hashable, Sendable {
  public let sourceListID: ReminderListReference
  public let name: String

  public init(sourceListID: ReminderListReference, name: String) {
    self.sourceListID = sourceListID
    self.name = name
  }

  private enum CodingKeys: String, CodingKey {
    case sourceListID = "source_list_id"
    case name
  }
}

public struct ReminderListUpdateRequest: Codable, Hashable, Sendable {
  public let id: ReminderListReference
  public let name: String

  public init(id: ReminderListReference, name: String) {
    self.id = id
    self.name = name
  }
}

public struct ReminderListDeleteResult: Codable, Hashable, Sendable {
  public let id: ReminderListReference
  public let deleted: Bool
  public let reminderCount: Int

  public init(id: ReminderListReference, deleted: Bool, reminderCount: Int) {
    self.id = id
    self.deleted = deleted
    self.reminderCount = reminderCount
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case deleted
    case reminderCount = "reminder_count"
  }
}

public protocol ReminderRepository: Sendable {
  func authorizationStatus() async -> ReminderAuthorizationStatus
  func requestFullAccess() async throws -> ReminderAuthorizationStatus
  func listLists() async throws -> [ReminderList]
  func listReminders(listID: ReminderListReference) async throws -> [ReminderItem]
  func getReminder(id: ReminderReference) async throws -> ReminderItem
  func createReminder(_ request: ReminderCreateRequest) async throws -> ReminderItem
  func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderItem
  func completeReminder(id: ReminderReference) async throws -> ReminderItem
  func deleteReminder(id: ReminderReference) async throws -> ReminderDeleteResult
  func createList(_ request: ReminderListCreateRequest) async throws -> ReminderList
  func updateList(_ request: ReminderListUpdateRequest) async throws -> ReminderList
  func deleteList(id: ReminderListReference) async throws -> ReminderListDeleteResult
}

public enum ReminderError: Error, LocalizedError, Equatable, Sendable {
  case permissionRequired
  case permissionDenied
  case permissionRestricted
  case permissionWriteOnly
  case eventStoreUnavailable
  case listNotFound
  case listNotWritable
  case listNotEmpty
  case reminderNotFound
  case ambiguousReference
  case invalidReference
  case unsupportedReferenceVersion
  case policyDenied(String)
  case idempotencyConflict
  case unsupportedDue
  case unsupportedRecurrence
  case writeFailed
  case invalidInput(String)
  case unknown

  public var code: String {
    switch self {
    case .permissionRequired: return "reminderPermissionRequired"
    case .permissionDenied: return "reminderPermissionDenied"
    case .permissionRestricted: return "reminderPermissionRestricted"
    case .permissionWriteOnly: return "reminderPermissionWriteOnly"
    case .eventStoreUnavailable: return "reminderEventStoreUnavailable"
    case .listNotFound: return "reminderListNotFound"
    case .listNotWritable: return "reminderListNotWritable"
    case .listNotEmpty: return "reminderListNotEmpty"
    case .reminderNotFound: return "reminderNotFound"
    case .ambiguousReference: return "ambiguousReference"
    case .invalidReference: return "invalidReference"
    case .unsupportedReferenceVersion: return "unsupportedReferenceVersion"
    case .policyDenied: return "reminderPolicyDenied"
    case .idempotencyConflict: return "idempotencyConflict"
    case .unsupportedDue: return "unsupportedDue"
    case .unsupportedRecurrence: return "unsupportedRecurrence"
    case .writeFailed: return "reminderWriteFailed"
    case .invalidInput: return "invalidInput"
    case .unknown: return "unknown"
    }
  }

  public var recovery: String? {
    switch self {
    case .permissionRequired:
      return "Run `apple-platform-mcp doctor --request-reminders`, then retry."
    case .permissionDenied, .permissionRestricted, .permissionWriteOnly:
      return "Allow Reminders Full Access for Apple Platform MCP in System Settings, then retry."
    case .listNotFound, .reminderNotFound:
      return "List the current Reminders references again and retry with a fresh reference."
    case .listNotWritable:
      return "Choose a Reminders list with can_write=true, then retry."
    case .listNotEmpty:
      return "Delete or move every Reminder in the selected list before deleting the list."
    case .invalidReference, .unsupportedReferenceVersion:
      return "Use the opaque reference returned by the current Reminders list tool."
    case .eventStoreUnavailable:
      return "Retry on a supported macOS host with EventKit available."
    case .policyDenied:
      return "Set reminder_mutation_mode=allowed in the local configuration, then retry."
    case .idempotencyConflict:
      return "Reuse an idempotency_key only with the same normalized operation and payload."
    case .writeFailed:
      return "Verify the selected Reminders list still permits changes, then retry."
    default:
      return nil
    }
  }

  public var errorDescription: String? {
    switch self {
    case .permissionRequired: return "Reminders Full Access has not been requested."
    case .permissionDenied: return "Reminders Full Access is denied."
    case .permissionRestricted: return "Reminders access is restricted by the system."
    case .permissionWriteOnly:
      return "Reminders access is write-only; reading requires Full Access."
    case .eventStoreUnavailable: return "The Reminders EventKit store is unavailable."
    case .listNotFound: return "The requested Reminders list was not found."
    case .listNotWritable: return "The requested Reminders list does not allow changes."
    case .listNotEmpty: return "The requested Reminders list is not empty."
    case .reminderNotFound: return "The requested reminder was not found."
    case .ambiguousReference: return "The reference resolved to more than one Reminders object."
    case .invalidReference: return "The Reminders reference is malformed."
    case .unsupportedReferenceVersion: return "The Reminders reference version is unsupported."
    case .policyDenied(let message): return message
    case .idempotencyConflict:
      return "The idempotency key was already used with a different operation or payload."
    case .unsupportedDue: return "The reminder due value cannot be represented safely."
    case .unsupportedRecurrence: return "The reminder recurrence cannot be represented safely."
    case .writeFailed: return "The Reminders backend rejected the requested change."
    case .invalidInput(let message): return message
    case .unknown: return "The Reminders operation failed without a normalized error."
    }
  }
}

private enum ReminderDateCodec {
  static func string(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  static func date(from string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string)
      ?? {
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
      }()
  }

  static func decode<Container: KeyedDecodingContainerProtocol>(
    _ container: Container,
    key: Container.Key
  ) throws -> Date? {
    guard let value = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
    guard let date = date(from: value) else {
      throw DecodingError.dataCorruptedError(
        forKey: key,
        in: container,
        debugDescription: "Expected an ISO-8601 date-time."
      )
    }
    return date
  }

  static func encode<Container: KeyedEncodingContainerProtocol>(
    _ date: Date?,
    into container: inout Container,
    key: Container.Key
  ) throws {
    try container.encodeIfPresent(date.map(string(from:)), forKey: key)
  }
}

extension ReminderDue {
  /// Converts a validated domain due value into the DateComponents shape used
  /// by EventKit. Timed values must carry an explicit IANA time-zone
  /// identifier; no process-local or machine-local time zone is inferred.
  func validatedDateComponents() throws -> DateComponents {
    switch self {
    case .allDay(let date):
      let utc = TimeZone(secondsFromGMT: 0)!
      guard let value = ReminderDateValueParser.dateOnly(date, timeZone: utc) else {
        throw ReminderError.unsupportedDue
      }

      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = utc
      var components = calendar.dateComponents([.year, .month, .day], from: value)
      components.timeZone = nil
      return components

    case .timed(let date, let time, let timeZoneIdentifier):
      guard
        let timeZoneIdentifier,
        let timeZone = TimeZone(identifier: timeZoneIdentifier),
        let value = ReminderDateValueParser.timed(
          date: date,
          time: time,
          timeZone: timeZone
        )
      else {
        throw ReminderError.unsupportedDue
      }

      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = timeZone
      var components = calendar.dateComponents(
        [.year, .month, .day, .hour, .minute, .second],
        from: value
      )
      components.timeZone = timeZone
      return components
    }
  }

  /// Used only for explicit read filters. All-day values use UTC midnight as
  /// a deterministic comparison anchor; timed values retain their EventKit
  /// time zone.
  func comparisonDate() -> Date? {
    switch self {
    case .allDay(let date):
      return ReminderDateValueParser.dateOnly(date, timeZone: TimeZone(secondsFromGMT: 0)!)
    case .timed(let date, let time, let timeZone):
      guard let timeZone, let zone = TimeZone(identifier: timeZone) else { return nil }
      return ReminderDateValueParser.timed(date: date, time: time, timeZone: zone)
    }
  }
}

enum ReminderDateValueParser {
  static func dateOnly(_ value: String, timeZone: TimeZone) -> Date? {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
      parts[0].count == 4,
      parts[1].count == 2,
      parts[2].count == 2,
      let year = Int(parts[0]),
      let month = Int(parts[1]),
      let day = Int(parts[2])
    else { return nil }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = DateComponents(year: year, month: month, day: day)
    guard let date = calendar.date(from: components) else { return nil }
    let actual = calendar.dateComponents([.year, .month, .day], from: date)
    return actual.year == year && actual.month == month && actual.day == day ? date : nil
  }

  static func timed(date: String, time: String, timeZone: TimeZone) -> Date? {
    let dateParts = date.split(separator: "-", omittingEmptySubsequences: false)
    let timeParts = time.split(separator: ":", omittingEmptySubsequences: false)
    guard dateParts.count == 3,
      timeParts.count == 3,
      dateParts[0].count == 4,
      dateParts[1].count == 2,
      dateParts[2].count == 2,
      timeParts[0].count == 2,
      timeParts[1].count == 2,
      timeParts[2].count == 2,
      let year = Int(dateParts[0]),
      let month = Int(dateParts[1]),
      let day = Int(dateParts[2]),
      let hour = Int(timeParts[0]),
      let minute = Int(timeParts[1]),
      let second = Int(timeParts[2]),
      (0..<24).contains(hour),
      (0..<60).contains(minute),
      (0..<60).contains(second)
    else { return nil }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = DateComponents(
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second
    )
    guard let value = calendar.date(from: components) else { return nil }
    let actual = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: value)
    guard actual.year == year,
      actual.month == month,
      actual.day == day,
      actual.hour == hour,
      actual.minute == minute,
      actual.second == second
    else { return nil }
    return value
  }
}
