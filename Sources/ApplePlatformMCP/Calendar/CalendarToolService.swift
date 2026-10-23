import Foundation

public actor CalendarToolService {
  private let repository: any CalendarRepository
  private let policy: CalendarPolicy
  private let journal: CalendarCreationJournal
  private let maxResults: Int
  private let maxBodyBytes: Int
  public nonisolated let mutationMode: CalendarMutationMode
  private struct Attempt {
    let fingerprint: String
    let task: Task<CalendarCreationResult, Error>
  }
  private var attempts: [String: Attempt] = [:]
  public init(
    repository: any CalendarRepository, policy: CalendarPolicy = .init(),
    journal: CalendarCreationJournal = .init(), maxResults: Int = 50, maxBodyBytes: Int = 262_144
  ) {
    self.repository = repository
    self.policy = policy
    self.journal = journal
    self.maxResults = min(1000, max(1, maxResults))
    self.maxBodyBytes = max(1, maxBodyBytes)
    self.mutationMode = policy.mode
  }
  public func authorizationStatus() async -> CalendarAccess {
    await repository.authorizationStatus()
  }
  private func requireAccess() async throws {
    switch await repository.authorizationStatus() {
    case .fullAccess: return
    case .notDetermined: throw CalendarError("calendarPermissionRequired")
    case .writeOnly: throw CalendarError("calendarPermissionWriteOnly")
    case .denied, .restricted: throw CalendarError("calendarPermissionDenied")
    case .unavailable: throw CalendarError("calendarUnavailable")
    }
  }
  public func listCalendars() async throws -> [CalendarDescriptor] {
    try await requireAccess()
    return try await repository.listCalendars().map { value in
      var result = value
      result.policyAllowsWrite = value.canWrite && policy.allowsWrite(value.id)
      return result
    }.sorted { $0.id < $1.id }
  }
  public func search(
    time: CalendarTimeRange, calendarIDs: [String]? = nil, query: String = "", limit: Int? = nil
  ) async throws -> CalendarSearchResult {
    let window = try time.validated()
    guard query.utf8.count <= 4096, limit == nil || limit! > 0,
      calendarIDs == nil || !calendarIDs!.isEmpty
    else { throw CalendarError("calendarInvalidInput") }
    try await requireAccess()
    let scan = try await repository.scan(window: window, calendarIDs: calendarIDs, maximum: 10_000)
    let matches = scan.records.filter {
      window.overlaps(start: $0.start, end: $0.end)
        && (query.isEmpty || $0.event.title.localizedCaseInsensitiveContains(query))
    }
    .sorted { ($0.start, $0.end, $0.event.id) < ($1.start, $1.end, $1.event.id) }
    let count = min(limit ?? maxResults, maxResults)
    return .init(
      items: matches.prefix(count).map { bounded($0.event) }, calendarIDs: scan.calendarIDs,
      truncated: !scan.complete || matches.count > count)
  }
  public func getEvent(id: String) async throws -> CalendarEvent {
    try await requireAccess()
    return bounded(try await repository.getEvent(id: id).event)
  }
  public func checkConflicts(time: CalendarTimeRange) async throws -> CalendarConflictResult {
    let window = try time.validated()
    try await requireAccess()
    return try await conflicts(window: window)
  }
  private func conflicts(window: CalendarWindow) async throws -> CalendarConflictResult {
    let scan = try await repository.scan(window: window, calendarIDs: nil, maximum: 10_000)
    let overlapping = scan.records.filter {
      window.overlaps(start: $0.start, end: $0.end) && $0.event.status != "cancelled"
        && $0.event.availability != "free"
    }
    .sorted { ($0.start, $0.event.id) < ($1.start, $1.event.id) }
    return .init(
      status: scan.complete ? "complete" : "incomplete",
      conflicts: overlapping.prefix(maxResults).map { bounded($0.event) }, count: overlapping.count,
      calendarIDs: scan.calendarIDs, truncated: !scan.complete || overlapping.count > maxResults)
  }
  public func create(_ request: CalendarCreateRequest, key: String) async throws
    -> CalendarCreationResult
  {
    try validateKey(key)
    let time = try request.time.canonical()
    let anchors = try CalendarReferenceCodec.decode(request.calendarID, kind: "calendar")
    let canonicalID = try CalendarReferenceCodec.calendar(
      source: anchors.source, calendar: anchors.calendar)
    try policy.validateWrite(canonicalID)
    let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, title.utf8.count <= 10_000, (request.location?.utf8.count ?? 0) <= 10_000,
      (request.notes?.utf8.count ?? 0) <= maxBodyBytes
    else { throw CalendarError("calendarInvalidInput") }
    try await requireAccess()
    let calendar = try await repository.writableCalendar(id: canonicalID)
    guard calendar.id == canonicalID, calendar.canWrite else {
      throw CalendarError("calendarNotWritable")
    }
    let normalized = CalendarCreateRequest(
      calendarID: canonicalID, title: title, time: time, location: request.location,
      notes: request.notes)
    let fingerprint = try CalendarCreationJournal.fingerprint(normalized)
    if let previous = attempts[key] {
      guard previous.fingerprint == fingerprint else {
        throw CalendarError("calendarIdempotencyConflict")
      }
      return try await previous.task.value
    }
    let task = Task<CalendarCreationResult, Error> {
      try await self.performCreate(normalized, key: key, fingerprint: fingerprint)
    }
    attempts[key] = Attempt(fingerprint: fingerprint, task: task)
    do {
      let result = try await task.value
      attempts.removeValue(forKey: key)
      return result
    } catch {
      attempts.removeValue(forKey: key)
      throw error
    }
  }
  private func performCreate(_ request: CalendarCreateRequest, key: String, fingerprint: String)
    async throws -> CalendarCreationResult
  {
    switch try await journal.reserve(key: key, fingerprint: fingerprint) {
    case .cached(let result): return result
    case .reserved: break
    }
    do {
      let conflict: CalendarConflictResult
      do { conflict = try await conflicts(window: request.time.validated()) } catch {
        conflict = .init(
          status: "failed", conflicts: [], count: 0, calendarIDs: [], truncated: true)
      }
      // Permission and destination are checked again by the repository immediately before save.
      let item = try await repository.createEvent(request)
      guard !item.event.id.isEmpty, item.event.calendarID == request.calendarID else {
        throw CalendarError("calendarCreationOutcomeUnknown")
      }
      var warnings: [String] = []
      if conflict.count > 0 { warnings.append("overlapping_events_detected") }
      if conflict.status != "complete" { warnings.append("conflict_check_" + conflict.status) }
      let result = CalendarCreationResult(
        eventID: item.event.id, calendarID: item.event.calendarID, conflictStatus: conflict.status,
        conflictCount: conflict.count, calendarIDsExamined: conflict.calendarIDs, warnings: warnings
      )
      try await journal.finish(key: key, fingerprint: fingerprint, result: result)
      return result
    } catch {
      // A reserved attempt survives every error/crash. Never equate an error with no EventKit write.
      throw CalendarError("calendarCreationOutcomeUnknown")
    }
  }
  public func creationOutcome(key: String) async throws -> CalendarCreationOutcome {
    try validateKey(key)
    try await requireAccess()
    if attempts[key] != nil { return .init(status: "in_flight", result: nil) }
    return try await journal.outcome(key: key)
  }
  private func validateKey(_ key: String) throws {
    guard !key.isEmpty, key == key.trimmingCharacters(in: .whitespacesAndNewlines),
      key.utf8.count <= 256
    else { throw CalendarError("calendarInvalidInput") }
  }
  private func bounded(_ value: CalendarEvent) -> CalendarEvent {
    var result = value
    if let notes = value.notes, notes.utf8.count > maxBodyBytes {
      var bytes = Array(notes.utf8.prefix(maxBodyBytes))
      while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
      result.notes = String(bytes: bytes, encoding: .utf8)
      result.truncated = true
    }
    return result
  }
}
