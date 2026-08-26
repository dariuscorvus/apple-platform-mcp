import Foundation
import MCP
import Testing

#if !XCODE_COMBINED_TEST_TARGET
  @testable import ApplePlatformMCPKit
#endif

@Suite("Reminder permission")
struct ReminderPermissionTests {
  @Test("normalizes EventKit authorization states without leaking EventKit types")
  func normalizesAuthorizationStates() {
    #expect(
      ReminderAuthorizationStatus.normalized(eventKitRawValue: 0) == .notDetermined)
    #expect(ReminderAuthorizationStatus.normalized(eventKitRawValue: 1) == .restricted)
    #expect(ReminderAuthorizationStatus.normalized(eventKitRawValue: 2) == .denied)
    #expect(ReminderAuthorizationStatus.normalized(eventKitRawValue: 3) == .fullAccess)
    #expect(ReminderAuthorizationStatus.normalized(eventKitRawValue: 4) == .writeOnly)
    #expect(ReminderAuthorizationStatus.normalized(eventKitRawValue: 99) == .unavailable)
  }

  @Test("keeps both current and legacy Reminders usage descriptions in the app plist")
  func usageDescriptionsAreConfigured() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let plistURL = repositoryRoot.appendingPathComponent("Config/ApplePlatformMCP-Info.plist")
    let data = try Data(contentsOf: plistURL)
    let plist = try #require(
      PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        as? [String: Any])

    #expect(
      (plist[ReminderPermissionRequirements.fullAccessUsageDescriptionKey] as? String)?.isEmpty
        == false)
    #expect(
      (plist[ReminderPermissionRequirements.legacyUsageDescriptionKey] as? String)?.isEmpty
        == false)
  }

  @Test("does not fetch reminders before full access")
  func noFetchBeforePermission() async throws {
    let repository = FakeReminderRepository(status: .notDetermined)
    let service = ReminderToolService(repository: repository, maxResults: 10)

    await #expect(throws: ReminderError.self) {
      try await service.listLists()
    }
    #expect(await repository.listListsCallCount == 0)
  }

  @Test("does not read lists when Reminders access is denied")
  func noListReadWhenDenied() async {
    let repository = FakeReminderRepository(status: .denied)
    let service = ReminderToolService(repository: repository)

    await #expect(throws: ReminderError.self) {
      try await service.listLists()
    }
    #expect(await repository.listListsCallCount == 0)
  }
}

@Suite("Reminder domain and references")
struct ReminderDomainTests {
  @Test("round-trips the public domain without EventKit values")
  func domainCodableRoundTrip() throws {
    let listID = ReminderReferenceCodec.list(
      calendarIdentifier: "calendar-secret-id",
      sourceIdentifier: "source-secret-id"
    )
    let reminderID = ReminderReferenceCodec.reminder(
      calendarIdentifier: "calendar-secret-id",
      calendarItemIdentifier: "item-secret-id",
      calendarItemExternalIdentifier: "external-secret-id"
    )
    let item = ReminderItem(
      id: reminderID,
      listID: listID,
      title: "Prepare fixture",
      notes: "No backend object crosses this boundary.",
      priority: 5,
      completed: false,
      completionDate: nil,
      due: .timed(
        date: "2026-08-26",
        time: "09:30:00",
        timeZone: "Europe/Berlin"
      ),
      recurrence: ReminderRecurrence(
        frequency: .weekly,
        interval: 2,
        weekdays: [.init(weekday: .wednesday)],
        endDate: Date(timeIntervalSince1970: 1_756_000_000)
      )
    )

    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(ReminderItem.self, from: data)

    #expect(decoded == item)
    #expect(String(data: data, encoding: .utf8)?.contains("item-secret-id") == false)
    #expect(String(data: data, encoding: .utf8)?.contains("external-secret-id") == false)
    #expect(String(data: data, encoding: .utf8)?.contains("calendar-secret-id") == false)
  }

  @Test("uses opaque versioned references and rejects malformed values")
  func referenceValidation() {
    let listID = ReminderReferenceCodec.list(calendarIdentifier: "calendar-secret-id")
    let reminderID = ReminderReferenceCodec.reminder(
      calendarIdentifier: "calendar-secret-id",
      calendarItemIdentifier: "item-secret-id"
    )

    #expect(listID.version == 1)
    #expect(reminderID.version == 1)
    #expect(listID.opaqueValue.hasPrefix("rr1_"))
    #expect(reminderID.opaqueValue.hasPrefix("rr1_"))
    #expect(ReminderReferenceCodec.isValid(listID))
    #expect(ReminderReferenceCodec.isValid(reminderID))
    #expect(
      !ReminderReferenceCodec.isValid(
        ReminderListReference(version: 2, opaqueValue: listID.opaqueValue)
      ))
    #expect(
      !ReminderReferenceCodec.isValid(
        ReminderReference(version: 1, opaqueValue: "rr1_not-base64")
      ))
    #expect(
      !ReminderReferenceCodec.isValid(
        ReminderReference(version: 1, opaqueValue: listID.opaqueValue)
      ))
  }

  @Test("re-encodes identical EventKit anchors deterministically")
  func referenceEncodingIsDeterministic() {
    let firstList = ReminderReferenceCodec.list(
      calendarIdentifier: "calendar-secret-id",
      sourceIdentifier: "source-secret-id"
    )
    let secondList = ReminderReferenceCodec.list(
      calendarIdentifier: "calendar-secret-id",
      sourceIdentifier: "source-secret-id"
    )
    let firstReminder = ReminderReferenceCodec.reminder(
      calendarIdentifier: "calendar-secret-id",
      calendarItemIdentifier: "item-secret-id",
      calendarItemExternalIdentifier: "external-secret-id",
      sourceIdentifier: "source-secret-id"
    )
    let secondReminder = ReminderReferenceCodec.reminder(
      calendarIdentifier: "calendar-secret-id",
      calendarItemIdentifier: "item-secret-id",
      calendarItemExternalIdentifier: "external-secret-id",
      sourceIdentifier: "source-secret-id"
    )

    #expect(firstList == secondList)
    #expect(firstReminder == secondReminder)
    #expect(firstReminder.opaqueValue.contains("item-secret-id") == false)
  }
}

@Suite("Reminder read service")
struct ReminderToolServiceTests {
  private static let listID = ReminderReferenceCodec.list(calendarIdentifier: "calendar-1")
  private static let otherListID = ReminderReferenceCodec.list(calendarIdentifier: "calendar-2")

  private static let incomplete = ReminderItem(
    id: ReminderReferenceCodec.reminder(
      calendarIdentifier: "calendar-1", calendarItemIdentifier: "item-1"),
    listID: listID,
    title: "Incomplete",
    priority: 1,
    completed: false,
    due: .allDay(date: "2026-08-26")
  )
  private static let completed = ReminderItem(
    id: ReminderReferenceCodec.reminder(
      calendarIdentifier: "calendar-1", calendarItemIdentifier: "item-2"),
    listID: listID,
    title: "Completed",
    priority: 9,
    completed: true,
    completionDate: Date(timeIntervalSince1970: 1_756_000_000),
    due: .timed(date: "2026-08-28", time: "12:00:00", timeZone: "Europe/Berlin")
  )
  private static let otherListItem = ReminderItem(
    id: ReminderReferenceCodec.reminder(
      calendarIdentifier: "calendar-2", calendarItemIdentifier: "item-3"),
    listID: otherListID,
    title: "Other list",
    priority: 0,
    completed: false
  )

  @Test("filters completion and due ranges, then applies the server limit")
  func filtersAndBoundsResults() async throws {
    let repository = FakeReminderRepository(
      lists: [
        ReminderList(id: Self.listID, name: "Fixture", capabilities: .init()),
        ReminderList(id: Self.otherListID, name: "Other", capabilities: .init()),
      ],
      reminders: [Self.incomplete, Self.completed, Self.otherListItem]
    )
    let service = ReminderToolService(repository: repository, maxResults: 1)
    let after = ISO8601DateFormatter().date(from: "2026-08-25T00:00:00Z")!
    let before = ISO8601DateFormatter().date(from: "2026-08-27T00:00:00Z")!

    let result = try await service.listReminders(
      listID: Self.listID,
      completed: false,
      dueAfter: after,
      dueBefore: before,
      limit: 50
    )

    #expect(result.map(\.title) == ["Incomplete"])
    #expect(await repository.lastRequestedListID == Self.listID)
  }

  @Test("rejects a floating timed due value for an explicit due filter")
  func rejectsFloatingDueFilter() async {
    let repository = FakeReminderRepository(
      lists: [ReminderList(id: Self.listID, name: "Fixture")],
      reminders: [
        ReminderItem(
          id: ReminderReferenceCodec.reminder(
            calendarIdentifier: "calendar-1", calendarItemIdentifier: "floating"),
          listID: Self.listID,
          title: "Floating",
          completed: false,
          due: .timed(date: "2026-08-26", time: "09:30:00", timeZone: nil)
        )
      ])
    let service = ReminderToolService(repository: repository)

    await #expect(throws: ReminderError.self) {
      try await service.listReminders(
        listID: Self.listID,
        dueAfter: Date(timeIntervalSince1970: 0)
      )
    }
  }

  @Test("lists multiple lists and preserves an empty result")
  func listsLists() async throws {
    let repository = FakeReminderRepository(
      lists: [
        ReminderList(id: Self.listID, name: "Fixture", capabilities: .init()),
        ReminderList(id: Self.otherListID, name: "Other", capabilities: .init()),
      ])
    let service = ReminderToolService(repository: repository)

    #expect(try await service.listLists().map(\.name) == ["Fixture", "Other"])

    let emptyService = ReminderToolService(repository: FakeReminderRepository())
    #expect(try await emptyService.listLists().isEmpty)
  }

  @Test("loads one reminder through its exact opaque reference")
  func getsReminder() async throws {
    let repository = FakeReminderRepository(
      lists: [ReminderList(id: Self.listID, name: "Fixture")],
      reminders: [Self.incomplete]
    )
    let service = ReminderToolService(repository: repository)

    let result = try await service.getReminder(id: Self.incomplete.id)

    #expect(result == Self.incomplete)
    #expect(await repository.getReminderCallCount == 1)
    #expect(await repository.lastRequestedReminderID == Self.incomplete.id)
  }

  @Test("rejects invalid reminder references before repository access")
  func rejectsInvalidReminderReference() async {
    let repository = FakeReminderRepository()
    let service = ReminderToolService(repository: repository)
    let malformed = ReminderReference(opaqueValue: "not-a-reminder-reference")

    await #expect(throws: ReminderError.self) {
      try await service.getReminder(id: malformed)
    }
    #expect(await repository.getReminderCallCount == 0)
  }

  @Test("returns a stable missing error for a stale reminder reference")
  func mapsMissingReminder() async {
    let repository = FakeReminderRepository(status: .fullAccess)
    let service = ReminderToolService(repository: repository)
    let stale = ReminderReferenceCodec.reminder(
      calendarIdentifier: "calendar-1",
      calendarItemIdentifier: "missing"
    )

    await #expect(throws: ReminderError.self) {
      try await service.getReminder(id: stale)
    }
    #expect(await repository.getReminderCallCount == 1)
  }

  @Test("rejects invalid list references before repository access")
  func rejectsInvalidListReference() async {
    let repository = FakeReminderRepository()
    let service = ReminderToolService(repository: repository)
    let malformed = ReminderListReference(opaqueValue: "not-a-reminder-reference")

    await #expect(throws: ReminderError.self) {
      try await service.listReminders(listID: malformed)
    }
    #expect(await repository.listRemindersCallCount == 0)
  }

  @Test("maps a missing list to a stable domain error")
  func mapsMissingList() async {
    let repository = FakeReminderRepository(status: .fullAccess)
    let service = ReminderToolService(repository: repository)
    let missing = ReminderReferenceCodec.list(calendarIdentifier: "missing")

    await #expect(throws: ReminderError.self) {
      try await service.listReminders(listID: missing)
    }
  }

  @Test("rejects an inverted due range before reading reminders")
  func rejectsInvertedDueRange() async {
    let repository = FakeReminderRepository(status: .fullAccess)
    let service = ReminderToolService(repository: repository)
    let listID = ReminderReferenceCodec.list(calendarIdentifier: "calendar-1")
    let after = Date(timeIntervalSince1970: 200)
    let before = Date(timeIntervalSince1970: 100)

    await #expect(throws: ReminderError.self) {
      try await service.listReminders(
        listID: listID,
        dueAfter: after,
        dueBefore: before
      )
    }
    #expect(await repository.listRemindersCallCount == 0)
  }
}

@Suite("Reminder MCP contract")
struct ReminderMCPContractTests {
  @Test("discovers and calls the complete Reminders read surface")
  func discoversReminderReadSurface() async throws {
    let listID = ReminderReferenceCodec.list(calendarIdentifier: "mcp-calendar")
    let reminderID = ReminderReferenceCodec.reminder(
      calendarIdentifier: "mcp-calendar",
      calendarItemIdentifier: "mcp-item"
    )
    let repository = FakeReminderRepository(
      lists: [ReminderList(id: listID, name: "MCP Fixture", capabilities: .init())],
      reminders: [
        ReminderItem(
          id: reminderID,
          listID: listID,
          title: "MCP reminder",
          notes: "Exact reminder text",
          priority: 0,
          completed: false
        )
      ]
    )
    let reminderService = ReminderToolService(repository: repository)
    let mailService = MailToolService(repository: EmptyMailRepository())
    let server = await ApplePlatformMCPServer(
      service: mailService,
      reminderService: reminderService
    ).makeServer()
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let serverTask = Task {
      try await server.start(transport: serverTransport)
      await server.waitUntilCompleted()
    }
    let client = Client(name: "reminder-contract-test", version: "1.0.0")

    _ = try await client.connect(transport: clientTransport)
    let listed = try await client.listTools()
    let names = Set(listed.tools.map(\.name))
    #expect(names.contains("reminder_list_lists"))
    #expect(names.contains("reminder_list_reminders"))
    #expect(names.contains("reminder_get_reminder"))

    let reminderTool = try #require(
      listed.tools.first(where: { $0.name == "reminder_list_reminders" }))
    let schema = try #require(reminderTool.inputSchema.objectValue)
    #expect(schema["additionalProperties"]?.boolValue == false)
    #expect(
      schema["required"]?.arrayValue?.compactMap(\.stringValue) == ["list_id"])
    #expect(
      schema["properties"]?.objectValue?["completed"]?.objectValue?["type"]?.stringValue
        == "boolean")
    #expect(
      schema["properties"]?.objectValue?["limit"]?.objectValue?["type"]?.stringValue
        == "integer")

    let getTool = try #require(
      listed.tools.first(where: { $0.name == "reminder_get_reminder" }))
    let getSchema = try #require(getTool.inputSchema.objectValue)
    #expect(getSchema["additionalProperties"]?.boolValue == false)
    #expect(
      getSchema["required"]?.arrayValue?.compactMap(\.stringValue) == ["reminder_id"])
    #expect(
      getSchema["properties"]?.objectValue?["reminder_id"]?.objectValue?["type"]?.stringValue
        == "string")

    let lists = try await client.callTool(name: "reminder_list_lists")
    #expect(lists.isError == false)
    #expect(textContent(lists.content).contains(listID.opaqueValue))

    let reminders = try await client.callTool(
      name: "reminder_list_reminders",
      arguments: ["list_id": .string(listID.opaqueValue), "limit": .int(1)]
    )
    #expect(reminders.isError == false)
    #expect(textContent(reminders.content).contains("MCP reminder"))

    let reminder = try await client.callTool(
      name: "reminder_get_reminder",
      arguments: ["reminder_id": .string(reminderID.opaqueValue)]
    )
    #expect(reminder.isError == false)
    #expect(textContent(reminder.content).contains("MCP reminder"))
    #expect(textContent(reminder.content).contains("Exact reminder text"))

    await client.disconnect()
    await serverTransport.disconnect()
    _ = try await serverTask.value
  }

  @Test("maps Reminders permission failures to the normalized MCP error")
  func mapsPermissionFailure() async throws {
    let reminderService = ReminderToolService(
      repository: FakeReminderRepository(status: .notDetermined))
    let mailService = MailToolService(repository: EmptyMailRepository())
    let server = await ApplePlatformMCPServer(
      service: mailService,
      reminderService: reminderService
    ).makeServer()
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let serverTask = Task {
      try await server.start(transport: serverTransport)
      await server.waitUntilCompleted()
    }
    let client = Client(name: "reminder-permission-test", version: "1.0.0")

    _ = try await client.connect(transport: clientTransport)
    let result = try await client.callTool(name: "reminder_list_lists")
    #expect(result.isError == true)
    #expect(textContent(result.content).contains("reminderPermissionRequired"))
    #expect(textContent(result.content).contains("doctor --request-reminders"))

    await client.disconnect()
    await serverTransport.disconnect()
    _ = try await serverTask.value
  }

  private func textContent(_ content: [Tool.Content]) -> String {
    content.compactMap { content in
      guard case .text(let value, _, _) = content else { return nil }
      return value
    }.joined()
  }
}

@Suite("Reminder EventKit value normalization")
struct ReminderEventKitValueNormalizationTests {
  @Test("maps EventKit's empty cleared-note representation to nil")
  func normalizesClearedNotes() {
    #expect(ReminderEventKitValueNormalizer.notes(nil) == nil)
    #expect(ReminderEventKitValueNormalizer.notes("") == nil)
    #expect(ReminderEventKitValueNormalizer.notes("Retained note") == "Retained note")
  }
}

@Suite("Reminder due validation")
struct ReminderDueValidationTests {
  @Test("maps an all-day due date to date-only components")
  func mapsAllDayDueDate() throws {
    let components = try ReminderDue.allDay(date: "2026-10-01").validatedDateComponents()

    #expect(components.year == 2026)
    #expect(components.month == 10)
    #expect(components.day == 1)
    #expect(components.timeZone == nil)
  }

  @Test("requires and preserves the explicit time zone for timed due values")
  func preservesTimedTimezone() throws {
    let components = try ReminderDue.timed(
      date: "2026-10-01",
      time: "09:30:00",
      timeZone: "Europe/Berlin"
    ).validatedDateComponents()

    #expect(components.hour == 9)
    #expect(components.minute == 30)
    #expect(components.timeZone?.identifier == "Europe/Berlin")
  }

  @Test("rejects a timed due value without an explicit time zone")
  func rejectsFloatingTimedDue() {
    #expect(throws: ReminderError.self) {
      try ReminderDue.timed(
        date: "2026-10-01",
        time: "09:30:00",
        timeZone: nil
      ).validatedDateComponents()
    }
  }
}

private actor FakeReminderRepository: ReminderRepository {
  var status: ReminderAuthorizationStatus
  let lists: [ReminderList]
  let reminders: [ReminderItem]
  private(set) var listListsCallCount = 0
  private(set) var listRemindersCallCount = 0
  private(set) var getReminderCallCount = 0
  private(set) var lastRequestedListID: ReminderListReference?
  private(set) var lastRequestedReminderID: ReminderReference?

  init(
    status: ReminderAuthorizationStatus = .fullAccess,
    lists: [ReminderList] = [],
    reminders: [ReminderItem] = []
  ) {
    self.status = status
    self.lists = lists
    self.reminders = reminders
  }

  func authorizationStatus() async -> ReminderAuthorizationStatus {
    status
  }

  func requestFullAccess() async throws -> ReminderAuthorizationStatus {
    status = .fullAccess
    return status
  }

  func listLists() async throws -> [ReminderList] {
    listListsCallCount += 1
    return lists
  }

  func listReminders(listID: ReminderListReference) async throws -> [ReminderItem] {
    listRemindersCallCount += 1
    lastRequestedListID = listID
    guard lists.contains(where: { $0.id == listID }) else {
      throw ReminderError.listNotFound
    }
    return reminders.filter { $0.listID == listID }
  }

  func getReminder(id: ReminderReference) async throws -> ReminderItem {
    getReminderCallCount += 1
    lastRequestedReminderID = id
    guard let reminder = reminders.first(where: { $0.id == id }) else {
      throw ReminderError.reminderNotFound
    }
    return reminder
  }

  func createReminder(_ request: ReminderCreateRequest) async throws -> ReminderItem {
    throw ReminderError.writeFailed
  }

  func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderItem {
    throw ReminderError.writeFailed
  }

  func completeReminder(id: ReminderReference) async throws -> ReminderItem {
    throw ReminderError.writeFailed
  }

  func deleteReminder(id: ReminderReference) async throws -> ReminderDeleteResult {
    throw ReminderError.writeFailed
  }

  func createList(_ request: ReminderListCreateRequest) async throws -> ReminderList {
    throw ReminderError.writeFailed
  }

  func updateList(_ request: ReminderListUpdateRequest) async throws -> ReminderList {
    throw ReminderError.writeFailed
  }

  func deleteList(id: ReminderListReference) async throws -> ReminderListDeleteResult {
    throw ReminderError.writeFailed
  }
}

private actor EmptyMailRepository: MailRepository {
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
