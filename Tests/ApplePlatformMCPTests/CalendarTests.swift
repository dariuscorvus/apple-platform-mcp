import Darwin
import Foundation
import MCP
import SQLite3
import Testing

#if !XCODE_COMBINED_TEST_TARGET
  @testable import ApplePlatformMCPKit
#endif

private func calendarError(_ expected: String, _ operation: () async throws -> Void) async {
  do {
    try await operation()
    Issue.record("Expected Calendar error: \(expected)")
  } catch let error as CalendarError { #expect(error.code == expected) } catch {
    Issue.record("Unexpected error type: \(type(of: error))")
  }
}
private func privateJournal() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "calendar-tests-" + UUID().uuidString)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return directory.appendingPathComponent("journal.sqlite3")
}
private func calendarID(_ raw: String = "calendar") throws -> String {
  try CalendarReferenceCodec.calendar(source: "source", calendar: raw)
}
private func timed(
  _ start: String = "2026-10-17T10:00:00+02:00", _ end: String = "2026-10-17T11:00:00+02:00"
) -> CalendarTimeRange {
  .init(start: start, end: end, timeZone: "Europe/Berlin")
}
private func fixtureEvent(
  raw: String = "event", calendar: String = "calendar", time: CalendarTimeRange = timed(),
  occurrence: Date? = nil, recurring: Bool = false, detached: Bool = false,
  status: String = "confirmed", availability: String = "busy", notes: String? = nil
) throws -> CalendarEventRecord {
  let w = try time.validated()
  let id = try CalendarReferenceCodec.event(
    source: "source", calendar: calendar, event: raw, occurrence: occurrence, start: w.start,
    end: w.end)
  return .init(
    event: .init(
      id: id, calendarID: try calendarID(calendar), title: raw, time: time,
      notes: notes, recurring: recurring, detached: detached, status: status,
      availability: availability), start: w.start, end: w.end)
}

@Suite("Calendar time and references")
struct CalendarTimeTests {
  @Test func validatesDSTOffsetsAndCalendarDays() throws {
    let spring = try timed("2026-03-29T01:30:00+01:00", "2026-03-29T03:30:00+02:00").validated()
    #expect(spring.end.timeIntervalSince(spring.start) == 3600)
    let springDay = try CalendarTimeRange(
      start: "2026-03-29", end: "2026-03-30", timeZone: "Europe/Berlin", allDay: true
    ).validated()
    #expect(springDay.end.timeIntervalSince(springDay.start) == 23 * 3600)
    let fallDay = try CalendarTimeRange(
      start: "2026-10-25", end: "2026-10-26", timeZone: "Europe/Berlin", allDay: true
    ).validated()
    #expect(fallDay.end.timeIntervalSince(fallDay.start) == 25 * 3600)
    let fall = try timed("2026-10-25T02:30:00+02:00", "2026-10-25T02:45:00+01:00").validated()
    #expect(fall.end.timeIntervalSince(fall.start) == 75 * 60)
  }
  @Test func rejectsInvalidOrImplicitTimeValues() {
    for time in [
      timed("2026-03-29T02:30:00+01:00", "2026-03-29T03:30:00+02:00"),
      timed("2026-10-17T10:00:00Z", "2026-10-17T11:00:00Z"),
      timed("2026-10-17T10:00:00", "2026-10-17T11:00:00"),
      timed("2026-02-30T10:00:00+01:00", "2026-02-30T11:00:00+01:00"),
      timed("2026-10-17T10:00:00+02:00", "2026-10-17T10:00:00+02:00"),
      CalendarTimeRange(
        start: "2026-01-01", end: "2027-01-03", timeZone: "Europe/Berlin", allDay: true),
      CalendarTimeRange(
        start: "2026-02-30", end: "2026-03-01", timeZone: "Europe/Berlin", allDay: true),
      CalendarTimeRange(start: "2026-10-17", end: "2026-10-18", timeZone: "invalid", allDay: true),
    ] { #expect(throws: CalendarError.self) { try time.validated() } }
  }
  @Test func halfOpenIntervalsPermitAdjacentEvents() throws {
    let window = try timed().validated()
    #expect(!window.overlaps(start: window.start.addingTimeInterval(-3600), end: window.start))
    #expect(!window.overlaps(start: window.end, end: window.end.addingTimeInterval(3600)))
    #expect(window.overlaps(start: window.start, end: window.end))
  }
  @Test func referenceEncodingIsCanonicalAndNamespacesAreStrict() throws {
    let first = try calendarID()
    for _ in 0..<32 { #expect(try calendarID() == first) }
    #expect(throws: CalendarError.self) { try CalendarReferenceCodec.decode(first, kind: "event") }
    #expect(throws: CalendarError.self) {
      try CalendarReferenceCodec.decode("notes_v1_bad", kind: "calendar")
    }
    let second = try fixtureEvent()
    #expect(
      try CalendarReferenceCodec.decode(second.event.id, kind: "event").calendar == "calendar")
  }
  @Test func resolvesExactOccurrencesIncludingMovedExceptions() throws {
    let first = try fixtureEvent(
      raw: "series", occurrence: timed().validated().start, recurring: true)
    let secondTime = timed("2026-10-18T10:00:00+02:00", "2026-10-18T11:00:00+02:00")
    let second = try fixtureEvent(
      raw: "series", time: secondTime, occurrence: secondTime.validated().start, recurring: true)
    let anchors = try CalendarReferenceCodec.decode(second.event.id, kind: "event")
    let scan = CalendarScan(
      records: [first, second], calendarIDs: [try calendarID()], complete: true)
    #expect(try CalendarOccurrenceResolver.resolve(anchors, scan: scan).event.id == second.event.id)
    let moved = try fixtureEvent(
      raw: "series", time: timed("2026-10-18T12:00:00+02:00", "2026-10-18T13:00:00+02:00"),
      occurrence: secondTime.validated().start, recurring: true, detached: true)
    #expect(throws: CalendarError("calendarEventNotFound")) {
      try CalendarOccurrenceResolver.resolve(
        anchors, scan: .init(records: [moved], calendarIDs: [], complete: true))
    }
    #expect(
      try CalendarOccurrenceResolver.resolve(
        CalendarReferenceCodec.decode(moved.event.id, kind: "event"),
        scan: .init(records: [first, moved], calendarIDs: [], complete: true)
      ).event.detached)
    #expect(throws: CalendarError("calendarAmbiguousReference")) {
      try CalendarOccurrenceResolver.resolve(
        anchors, scan: .init(records: [second, second], calendarIDs: [], complete: true))
    }
    #expect(throws: CalendarError("calendarTraversalLimit")) {
      try CalendarOccurrenceResolver.resolve(
        anchors, scan: .init(records: [second], calendarIDs: [], complete: false))
    }
  }
}

@Suite("Calendar policy and reads")
struct CalendarPolicyTests {
  @Test func configurationDefaultsAndIndependentGates() throws {
    let empty = try JSONDecoder().decode(MailServerConfiguration.self, from: Data("{}".utf8))
    #expect(empty.calendarMutationMode == .denied && empty.calendarAllowedWriteCalendarIDs.isEmpty)
    let existing = try JSONDecoder().decode(
      MailServerConfiguration.self,
      from: Data(
        #"{"mutation_mode":"allowed","notes_mutation_mode":"allowed","reminder_mutation_mode":"allowed"}"#
          .utf8))
    #expect(existing.calendarMutationMode == .denied)
    for invalid in [
      #"{"calendar_mutation_mode":"typo"}"#, #"{"calendar_journal_path":"relative.db"}"#,
    ] {
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(MailServerConfiguration.self, from: Data(invalid.utf8))
      }
    }
    #expect(try ApplePlatformMCPCommand.parse(["doctor", "--request-calendar"]) == .doctorCalendar)
  }
  @Test func noImplicitPermissionPromptOrStoreReads() async throws {
    for access in [CalendarAccess.notDetermined, .denied, .restricted, .writeOnly, .unavailable] {
      let repo = CalendarFakeRepository(access: access)
      let service = CalendarToolService(repository: repo)
      await #expect(throws: CalendarError.self) { try await service.listCalendars() }
      #expect(await repo.reads == 0)
      #expect(await repo.permissionRequests == 0)
    }
  }
  @Test func calendarUsageDescriptionsExist() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let plist = try #require(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: root.appendingPathComponent("Config/ApplePlatformMCP-Info.plist")),
        format: nil) as? [String: Any])
    #expect((plist["NSCalendarsFullAccessUsageDescription"] as? String)?.isEmpty == false)
    #expect((plist["NSCalendarsUsageDescription"] as? String)?.isEmpty == false)
  }
  @Test func disabledOrUnlistedWritesNeverReachBackend() async throws {
    let url = try privateJournal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    for policy in [
      CalendarPolicy(), .init(mode: .confirmationRequired, allowedWriteIDs: [try calendarID()]),
      .init(mode: .allowed),
    ] {
      let repo = CalendarFakeRepository()
      let service = CalendarToolService(repository: repo, policy: policy, journal: .init(url: url))
      await calendarError("calendarPolicyDenied") {
        _ = try await service.create(
          .init(calendarID: calendarID(), title: "Test", time: timed()), key: "denied")
      }
      #expect(await repo.creates == 0)
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }
  @Test func providerReadOnlyCalendarIsRefused() async throws {
    let repo = CalendarFakeRepository(writable: false)
    let service = CalendarToolService(
      repository: repo, policy: .init(mode: .allowed, allowedWriteIDs: [try calendarID()]))
    await calendarError("calendarNotWritable") {
      _ = try await service.create(
        .init(calendarID: calendarID(), title: "Test", time: timed()), key: "readonly")
    }
    #expect(await repo.creates == 0)
  }
  @Test func boundedSearchAndConflictsKeepCompletenessSeparate() async throws {
    let first = try fixtureEvent(raw: "first")
    let second = try fixtureEvent(raw: "second", calendar: "other")
    let free = try fixtureEvent(raw: "free", availability: "free")
    let cancelled = try fixtureEvent(raw: "cancelled", status: "cancelled")
    let adjacent = try fixtureEvent(
      raw: "adjacent", time: timed("2026-10-17T11:00:00+02:00", "2026-10-17T12:00:00+02:00"))
    let repo = CalendarFakeRepository(records: [second, adjacent, free, cancelled, first])
    let service = CalendarToolService(repository: repo, maxResults: 1)
    let search = try await service.search(time: timed())
    #expect(search.items.count == 1 && search.truncated)
    let conflicts = try await service.checkConflicts(time: timed())
    #expect(conflicts.count == 2 && conflicts.conflicts.count == 1 && conflicts.truncated)
    #expect(conflicts.status == "complete")
    #expect(conflicts.calendarIDs.count == 2)
    await repo.setComplete(false)
    #expect(try await service.checkConflicts(time: timed()).status == "incomplete")
  }
  @Test func outputNotesAreBoundedOnUTF8Boundary() async throws {
    let record = try fixtureEvent(notes: "äöü test")
    let service = CalendarToolService(
      repository: CalendarFakeRepository(records: [record]), maxBodyBytes: 5)
    let event = try await service.getEvent(id: record.event.id)
    #expect(event.notes == "äö" && event.truncated)
  }
}

@Suite("Calendar durable creation")
struct CalendarJournalTests {
  @Test func successfulRetriesSurviveNewServiceAndJournalInstances() async throws {
    let url = try privateJournal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let repo = CalendarFakeRepository(records: [try fixtureEvent()])
    let policy = CalendarPolicy(mode: .allowed, allowedWriteIDs: [try calendarID()])
    let request = CalendarCreateRequest(
      calendarID: try calendarID(), title: "Synthetic private title", time: timed(),
      notes: "Synthetic private body")
    let first = CalendarToolService(repository: repo, policy: policy, journal: .init(url: url))
    async let a = first.create(request, key: "stable")
    async let b = first.create(request, key: "stable")
    let results = try await [a, b]
    #expect(results[0] == results[1])
    #expect(results[0].warnings.contains("overlapping_events_detected"))
    let restarted = CalendarToolService(repository: repo, policy: policy, journal: .init(url: url))
    #expect(try await restarted.create(request, key: "stable") == results[0])
    #expect(try await restarted.creationOutcome(key: "stable").status == "succeeded")
    #expect(await repo.creates == 1)
    let changed = CalendarCreateRequest(
      calendarID: try calendarID(), title: "Different", time: timed())
    await calendarError("calendarIdempotencyConflict") {
      _ = try await restarted.create(changed, key: "stable")
    }
    let bytes = try Data(contentsOf: url)
    #expect(bytes.range(of: Data("Synthetic private title".utf8)) == nil)
    #expect(bytes.range(of: Data("Synthetic private body".utf8)) == nil)
    #expect(
      (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
        .intValue == 0o600)
  }
  @Test func twoConnectionsCannotReserveTwoWrites() async throws {
    let url = try privateJournal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let a = CalendarCreationJournal(url: url)
    let b = CalendarCreationJournal(url: url)
    let first = try await a.reserve(key: "once", fingerprint: "same")
    guard case .reserved = first else {
      Issue.record("First request must reserve")
      return
    }
    await calendarError("calendarCreationOutcomeUnknown") {
      _ = try await b.reserve(key: "once", fingerprint: "same")
    }
    await calendarError("calendarIdempotencyConflict") {
      _ = try await b.reserve(key: "once", fingerprint: "changed")
    }
    #expect(try await b.outcome(key: "once").status == "outcome_unknown")
  }
  @Test func separateServicesRacingOnOneJournalSaveAtMostOnce() async throws {
    let url = try privateJournal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let repo = CalendarFakeRepository()
    let policy = CalendarPolicy(mode: .allowed, allowedWriteIDs: [try calendarID()])
    let request = CalendarCreateRequest(calendarID: try calendarID(), title: "Race", time: timed())
    let services = [
      CalendarToolService(repository: repo, policy: policy, journal: .init(url: url)),
      CalendarToolService(repository: repo, policy: policy, journal: .init(url: url)),
    ]
    let successes = await withTaskGroup(of: Bool.self) { group in
      for service in services {
        group.addTask {
          do {
            _ = try await service.create(request, key: "race")
            return true
          } catch let error as CalendarError {
            #expect(
              ["calendarCreationOutcomeUnknown", "calendarJournalUnavailable"].contains(error.code))
            return false
          } catch {
            Issue.record("Unexpected race error")
            return false
          }
        }
      }
      var values: [Bool] = []
      for await success in group { values.append(success) }
      return values
    }
    #expect(successes.contains(true))
    #expect(await repo.creates == 1)
    _ = try await services[0].create(request, key: "race")
    #expect(await repo.creates == 1)
  }
  @Test func pendingReservationFromAnotherProcessBlocksSave() async throws {
    let url = try privateJournal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let journal = CalendarCreationJournal(url: url)
    _ = try await journal.reserve(key: "initialize-schema", fingerprint: "schema")
    let request = CalendarCreateRequest(
      calendarID: try calendarID(), title: "Test", time: try timed().canonical())
    let fingerprint = try CalendarCreationJournal.fingerprint(request)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      "-c",
      "import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1]); c.execute('BEGIN IMMEDIATE'); c.execute(\"INSERT INTO calendar_creations(key_hash,fingerprint,state,created_at) VALUES(?,?,'pending','synthetic')\",(sys.argv[2],sys.argv[3])); print('reserved',flush=True); time.sleep(0.3); c.commit()",
      url.path, CalendarCreationJournal.hash("cross-process"), fingerprint,
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let ready = pipe.fileHandleForReading.availableData
    #expect(String(decoding: ready, as: UTF8.self).contains("reserved"))
    let repo = CalendarFakeRepository()
    let service = CalendarToolService(
      repository: repo, policy: .init(mode: .allowed, allowedWriteIDs: [try calendarID()]),
      journal: journal)
    await calendarError("calendarCreationOutcomeUnknown") {
      _ = try await service.create(request, key: "cross-process")
    }
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(await repo.creates == 0)
  }
  @Test func crashWindowAfterSaveRemainsUnknownWithoutRetry() async throws {
    let url = try privateJournal()
    defer {
      chmod(url.path, 0o600)
      try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    let repo = CalendarFakeRepository(makeJournalUnreadableAfterSave: url)
    let policy = CalendarPolicy(mode: .allowed, allowedWriteIDs: [try calendarID()])
    let request = CalendarCreateRequest(calendarID: try calendarID(), title: "Test", time: timed())
    let service = CalendarToolService(repository: repo, policy: policy, journal: .init(url: url))
    await calendarError("calendarCreationOutcomeUnknown") {
      _ = try await service.create(request, key: "crash")
    }
    chmod(url.path, 0o600)
    let restarted = CalendarToolService(repository: repo, policy: policy, journal: .init(url: url))
    #expect(try await restarted.creationOutcome(key: "crash").status == "outcome_unknown")
    await calendarError("calendarCreationOutcomeUnknown") {
      _ = try await restarted.create(request, key: "crash")
    }
    #expect(await repo.creates == 1)
  }
  @Test func unavailableJournalPreventsBackendWrite() async throws {
    let url = try privateJournal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    let repo = CalendarFakeRepository()
    let service = CalendarToolService(
      repository: repo, policy: .init(mode: .allowed, allowedWriteIDs: [try calendarID()]),
      journal: .init(url: url))
    await calendarError("calendarJournalUnavailable") {
      _ = try await service.create(
        .init(calendarID: calendarID(), title: "Test", time: timed()), key: "unavailable")
    }
    #expect(await repo.creates == 0)
  }
  @Test func linkedCorruptAndUnexpectedEmptyJournalsAreRefused() async throws {
    for kind in ["linked", "corrupt", "empty"] {
      let url = try privateJournal()
      defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
      if kind == "linked" {
        let target = url.deletingLastPathComponent().appendingPathComponent("target.db")
        try Data("synthetic".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
      } else {
        FileManager.default.createFile(
          atPath: url.path, contents: kind == "corrupt" ? Data("not sqlite".utf8) : Data(),
          attributes: [.posixPermissions: 0o600])
      }
      await calendarError("calendarJournalUnavailable") {
        _ = try await CalendarCreationJournal(url: url).reserve(
          key: "no-write", fingerprint: "test")
      }
    }
  }
  @Test func incompleteAndFailedConflictChecksWarnButCreate() async throws {
    for fail in [false, true] {
      let url = try privateJournal()
      defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
      let repo = CalendarFakeRepository(complete: false, failScan: fail)
      let service = CalendarToolService(
        repository: repo, policy: .init(mode: .allowed, allowedWriteIDs: [try calendarID()]),
        journal: .init(url: url))
      let result = try await service.create(
        .init(calendarID: calendarID(), title: "Test", time: timed()), key: "warning")
      #expect(result.conflictStatus == (fail ? "failed" : "incomplete"))
      #expect(result.warnings.contains("conflict_check_" + result.conflictStatus))
      #expect(await repo.creates == 1)
    }
  }
}

@Suite("Calendar MCP contract")
struct CalendarContractTests {
  @Test func nativeHTTPDispatchesCalendarReadsAndValidation() async throws {
    let url = try privateJournal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let server = await ApplePlatformMCPServer(
      service: MailToolService(repository: CalendarEmptyMailRepository()),
      calendarService: CalendarToolService(
        repository: CalendarFakeRepository(), journal: .init(url: url))
    ).makeServer()
    let runtime = ApplePlatformMCPStreamableHTTPRuntime(server: server, readinessProbe: { true })
    try await runtime.start()
    func request(_ body: String) -> HTTPRequest {
      .init(
        method: "POST",
        headers: [
          "Accept": "application/json", "Content-Type": "application/json",
          "MCP-Protocol-Version": "2025-06-18",
        ], body: Data(body.utf8), path: "/mcp")
    }
    _ = await runtime.handle(
      request(
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"calendar-http","version":"1"}}}"#
      ))
    _ = await runtime.handle(request(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    let response = await runtime.handle(
      request(
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"calendar_list_calendars","arguments":{}}}"#
      ))
    #expect(response.statusCode == 200)
    let body = try #require(response.bodyData)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let result = try #require(json["result"] as? [String: Any])
    #expect(result["isError"] as? Bool != true)
    let invalid = await runtime.handle(
      request(
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"calendar_list_calendars","arguments":{"extra":true}}}"#
      ))
    let invalidBody = try #require(invalid.bodyData)
    let invalidJSON = try #require(
      JSONSerialization.jsonObject(with: invalidBody) as? [String: Any])
    #expect((invalidJSON["result"] as? [String: Any])?["isError"] as? Bool == true)
    await runtime.stop()
  }
  @Test func catalogRoutingAndStrictArguments() async throws {
    let url = try privateJournal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let record = try fixtureEvent()
    let server = await ApplePlatformMCPServer(
      service: MailToolService(repository: CalendarEmptyMailRepository()),
      calendarService: CalendarToolService(
        repository: CalendarFakeRepository(records: [record]), journal: .init(url: url))
    ).makeServer()
    let (ct, st) = await InMemoryTransport.createConnectedPair()
    let task = Task { try await server.start(transport: st) }
    let client = Client(name: "calendar-contract", version: "1")
    _ = try await client.connect(transport: ct)
    let tools = try await client.listTools()
    #expect(tools.tools.filter { $0.name.hasPrefix("calendar_") }.count == 6)
    #expect(try await client.callTool(name: "calendar_list_calendars").isError != true)
    let validTime: Value = .object([
      "start": .string("2026-10-17T10:00:00+02:00"), "end": .string("2026-10-17T11:00:00+02:00"),
      "time_zone": .string("Europe/Berlin"),
    ])
    for args: [String: Value] in [
      ["time": validTime, "limit": .string("2")], ["time": validTime, "calendar_ids": .array([])],
      ["time": validTime, "participants": .array([])],
      [
        "time": .object([
          "start": .string("bad"), "end": .string("bad"), "time_zone": .string("UTC"),
          "extra": .bool(true),
        ])
      ],
    ] {
      #expect(
        try await client.callTool(name: "calendar_search_events", arguments: args).isError == true)
    }
    let denied = try await client.callTool(
      name: "calendar_create_event",
      arguments: [
        "calendar_id": .string(calendarID()), "title": .string("Test"), "time": validTime,
        "idempotency_key": .string("key"),
      ])
    #expect(denied.isError == true)
    let read = try await client.callTool(
      name: "calendar_get_event", arguments: ["event_id": .string(record.event.id)])
    #expect(read.isError != true)
    let outcome = try await client.callTool(
      name: "calendar_get_creation_outcome", arguments: ["idempotency_key": .string("missing")])
    #expect(outcome.isError != true)
    let search = try await client.callTool(
      name: "calendar_search_events", arguments: ["time": validTime])
    #expect(search.isError != true)
    let conflict = try await client.callTool(
      name: "calendar_check_conflicts", arguments: ["time": validTime])
    #expect(conflict.isError != true)
    await client.disconnect()
    await server.stop()
    _ = try await task.value
  }
}

private actor CalendarFakeRepository: CalendarRepository {
  let access: CalendarAccess
  let writable: Bool
  var records: [CalendarEventRecord]
  var complete: Bool
  let failScan: Bool
  let faultURL: URL?
  var reads = 0
  var creates = 0
  var permissionRequests = 0
  init(
    access: CalendarAccess = .fullAccess, writable: Bool = true,
    records: [CalendarEventRecord] = [], complete: Bool = true,
    failScan: Bool = false, makeJournalUnreadableAfterSave: URL? = nil
  ) {
    self.access = access
    self.writable = writable
    self.records = records
    self.complete = complete
    self.failScan = failScan
    self.faultURL = makeJournalUnreadableAfterSave
  }
  func authorizationStatus() async -> CalendarAccess { access }
  func requestFullAccess() async throws -> CalendarAccess {
    permissionRequests += 1
    return access
  }
  func setComplete(_ value: Bool) { complete = value }
  func listCalendars() async throws -> [CalendarDescriptor] {
    reads += 1
    return [
      .init(id: try calendarID(), name: "Test", source: "Synthetic", canWrite: writable),
      .init(id: try calendarID("other"), name: "Other", source: "Synthetic", canWrite: true),
    ]
  }
  func writableCalendar(id: String) async throws -> CalendarDescriptor {
    let values = try await listCalendars()
    guard let found = values.first(where: { $0.id == id }) else {
      throw CalendarError("calendarNotFound")
    }
    guard found.canWrite else { throw CalendarError("calendarNotWritable") }
    return found
  }
  func scan(window: CalendarWindow, calendarIDs: [String]?, maximum: Int) async throws
    -> CalendarScan
  {
    reads += 1
    if failScan { throw CalendarError("calendarUnavailable") }
    let ids = try calendarIDs ?? [calendarID(), calendarID("other")]
    let matches = records.filter {
      ids.contains($0.event.calendarID) && window.overlaps(start: $0.start, end: $0.end)
    }
    return .init(
      records: Array(matches.prefix(maximum)), calendarIDs: ids,
      complete: complete && matches.count <= maximum)
  }
  func getEvent(id: String) async throws -> CalendarEventRecord {
    reads += 1
    return try CalendarOccurrenceResolver.resolve(
      CalendarReferenceCodec.decode(id, kind: "event"),
      scan: .init(records: records, calendarIDs: [], complete: true))
  }
  func createEvent(_ request: CalendarCreateRequest) async throws -> CalendarEventRecord {
    creates += 1
    try await Task.sleep(for: .milliseconds(10))
    let record = try fixtureEvent(raw: "created-\(creates)", time: request.time)
    records.append(record)
    if let faultURL { chmod(faultURL.path, 0) }
    return record
  }
}

private actor CalendarEmptyMailRepository: MailRepository {
  func listAccounts(includeDisabled: Bool) async throws -> [MailAccountModel] { [] }
  func listMailboxes(accountID: AccountReference, includeCounts: Bool) async throws -> [Mailbox] {
    []
  }
  func searchMessages(_ query: MailSearchQuery) async throws -> MailSearchPage {
    MailSearchPage(messages: [])
  }
  func getMessage(
    id: MessageReference,
    includeBody: Bool,
    bodyFormat: MailBodyFormat,
    includeAttachmentMetadata: Bool,
    maxBodyBytes: Int
  ) async throws -> MailMessageRecord {
    throw MailError.messageNotFound
  }
  func sendMessage(_ request: MailSendRequest) async throws -> MailSendResult {
    throw MailError.unsupportedByAccount
  }
  func createDraft(_ request: MailDraftRequest) async throws -> MailDraftResult {
    throw MailError.unsupportedByAccount
  }
  func moveMessage(
    id: MessageReference,
    to mailboxID: MailboxReference
  ) async throws -> MailMessageMutationResult {
    throw MailError.unsupportedByAccount
  }
  func trashMessage(_ id: MessageReference) async throws -> MailMessageMutationResult {
    throw MailError.unsupportedByAccount
  }
  func updateMessage(_ request: MailMessageUpdateRequest) async throws -> MailMessageMutationResult
  {
    throw MailError.unsupportedByAccount
  }
}
