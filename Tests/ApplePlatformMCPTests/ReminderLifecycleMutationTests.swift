import Foundation
import MCP
import Testing

#if !XCODE_COMBINED_TEST_TARGET
  @testable import ApplePlatformMCPKit
#endif

@Suite("Reminder lifecycle service")
struct ReminderLifecycleServiceTests {
  private static let listID = ReminderReferenceCodec.list(calendarIdentifier: "mutable-calendar")
  private static let otherListID = ReminderReferenceCodec.list(calendarIdentifier: "other-calendar")
  private static let existingReminder = ReminderItem(
    id: ReminderReferenceCodec.reminder(
      calendarIdentifier: "mutable-calendar",
      calendarItemIdentifier: "existing-item"
    ),
    listID: listID,
    title: "Existing reminder",
    notes: "Existing notes",
    priority: 1,
    completed: false
  )

  @Test("denies a Reminder create before repository delegation by default")
  func deniesCreateByDefault() async {
    let repository = MutableReminderRepository(lists: [ReminderList(id: Self.listID, name: "Fixture")])
    let service = ReminderToolService(repository: repository)

    await #expect(throws: ReminderError.self) {
      try await service.createReminder(
        ReminderCreateRequest(listID: Self.listID, title: "Blocked"),
        idempotencyKey: "blocked-create"
      )
    }

    #expect(await repository.createCallCount == 0)
  }

  @Test("creates a Reminder once and returns the same normalized result on retry")
  func createsExactlyOnce() async throws {
    let repository = MutableReminderRepository(lists: [ReminderList(id: Self.listID, name: "Fixture")])
    let service = ReminderToolService(
      repository: repository,
      policy: .init(mutationMode: .allowed)
    )
    let request = ReminderCreateRequest(
      listID: Self.listID,
      title: "Create fixture",
      notes: "A note",
      priority: 5
    )

    let first = try await service.createReminder(request, idempotencyKey: "create-fixture")
    let retry = try await service.createReminder(request, idempotencyKey: "create-fixture")

    #expect(first == retry)
    #expect(first.title == "Create fixture")
    #expect(first.notes == "A note")
    #expect(first.priority == 5)
    #expect(ReminderReferenceCodec.isValid(first.id))
    #expect(await repository.createCallCount == 1)
  }

  @Test("updates selected fields, clears notes, and preserves omitted fields")
  func patchesReminderExactlyOnce() async throws {
    let repository = MutableReminderRepository(
      lists: [
        ReminderList(id: Self.listID, name: "Fixture"),
        ReminderList(id: Self.otherListID, name: "Other"),
      ],
      reminders: [Self.existingReminder]
    )
    let service = ReminderToolService(
      repository: repository,
      policy: .init(mutationMode: .allowed)
    )
    let request = ReminderUpdateRequest(
      id: Self.existingReminder.id,
      listID: .set(Self.otherListID),
      title: .set("Updated reminder"),
      notes: .clear,
      priority: .set(9)
    )

    let first = try await service.updateReminder(request, idempotencyKey: "update-fixture")
    let retry = try await service.updateReminder(request, idempotencyKey: "update-fixture")

    #expect(first == retry)
    #expect(first.listID == Self.otherListID)
    #expect(first.title == "Updated reminder")
    #expect(first.notes == nil)
    #expect(first.priority == 9)
    #expect(first.completed == false)
    #expect(await repository.updateCallCount == 1)
  }

  @Test("rejects empty patches and malformed references before a mutation")
  func rejectsUnsafePatchesBeforeRepositoryDelegation() async {
    let repository = MutableReminderRepository(
      lists: [ReminderList(id: Self.listID, name: "Fixture")],
      reminders: [Self.existingReminder]
    )
    let service = ReminderToolService(
      repository: repository,
      policy: .init(mutationMode: .allowed)
    )

    await #expect(throws: ReminderError.self) {
      try await service.updateReminder(
        ReminderUpdateRequest(id: Self.existingReminder.id),
        idempotencyKey: "empty-patch"
      )
    }
    await #expect(throws: ReminderError.self) {
      try await service.deleteReminder(
        id: ReminderReference(opaqueValue: "malformed"),
        idempotencyKey: "bad-reference"
      )
    }

    #expect(await repository.updateCallCount == 0)
    #expect(await repository.deleteCallCount == 0)
  }

  @Test("completes and deletes only the explicitly referenced Reminder")
  func completesAndDeletesExplicitReminder() async throws {
    let repository = MutableReminderRepository(
      lists: [ReminderList(id: Self.listID, name: "Fixture")],
      reminders: [Self.existingReminder]
    )
    let service = ReminderToolService(
      repository: repository,
      policy: .init(mutationMode: .allowed)
    )

    let completed = try await service.completeReminder(
      id: Self.existingReminder.id,
      idempotencyKey: "complete-fixture"
    )
    let completedRetry = try await service.completeReminder(
      id: Self.existingReminder.id,
      idempotencyKey: "complete-fixture"
    )
    let deleted = try await service.deleteReminder(
      id: Self.existingReminder.id,
      idempotencyKey: "delete-fixture"
    )
    let deletedRetry = try await service.deleteReminder(
      id: Self.existingReminder.id,
      idempotencyKey: "delete-fixture"
    )

    #expect(completed.completed)
    #expect(completed.completionDate != nil)
    #expect(completedRetry == completed)
    #expect(deleted.id == Self.existingReminder.id)
    #expect(deleted.deleted)
    #expect(deletedRetry == deleted)
    #expect(await repository.completeCallCount == 1)
    #expect(await repository.deleteCallCount == 1)
  }

  @Test("rejects a reused idempotency key with a different operation")
  func rejectsCrossOperationIdempotencyReuse() async throws {
    let repository = MutableReminderRepository(lists: [ReminderList(id: Self.listID, name: "Fixture")])
    let service = ReminderToolService(
      repository: repository,
      policy: .init(mutationMode: .allowed)
    )
    let created = try await service.createReminder(
      ReminderCreateRequest(listID: Self.listID, title: "Create fixture"),
      idempotencyKey: "shared-key"
    )

    await #expect(throws: ReminderError.self) {
      try await service.completeReminder(id: created.id, idempotencyKey: "shared-key")
    }
    #expect(await repository.completeCallCount == 0)
  }
}

@Suite("Reminder list lifecycle service")
struct ReminderListLifecycleServiceTests {
  private static let sourceListID = ReminderReferenceCodec.list(calendarIdentifier: "list-source")
  private static let occupiedListID = ReminderReferenceCodec.list(calendarIdentifier: "list-occupied")
  private static let occupiedReminder = ReminderItem(
    id: ReminderReferenceCodec.reminder(
      calendarIdentifier: "list-occupied",
      calendarItemIdentifier: "occupied-item"
    ),
    listID: occupiedListID,
    title: "Keeps the list non-empty",
    completed: false
  )

  @Test("creates, renames, and deletes an empty isolated list exactly once per key")
  func managesAnIsolatedList() async throws {
    let repository = MutableReminderRepository(
      lists: [ReminderList(id: Self.sourceListID, name: "Source")]
    )
    let service = ReminderToolService(
      repository: repository,
      policy: .init(mutationMode: .allowed, listDeleteEnabled: true)
    )
    let createRequest = ReminderListCreateRequest(
      sourceListID: Self.sourceListID,
      name: "Isolated smoke list"
    )

    let created = try await service.createList(createRequest, idempotencyKey: "list-create")
    let createRetry = try await service.createList(createRequest, idempotencyKey: "list-create")
    let updated = try await service.updateList(
      ReminderListUpdateRequest(id: created.id, name: "Renamed smoke list"),
      idempotencyKey: "list-update"
    )
    let updateRetry = try await service.updateList(
      ReminderListUpdateRequest(id: created.id, name: "Renamed smoke list"),
      idempotencyKey: "list-update"
    )
    let deleted = try await service.deleteList(id: created.id, idempotencyKey: "list-delete")
    let deleteRetry = try await service.deleteList(id: created.id, idempotencyKey: "list-delete")

    #expect(created == createRetry)
    #expect(updated == updateRetry)
    #expect(updated.name == "Renamed smoke list")
    #expect(deleted == deleteRetry)
    #expect(deleted.deleted)
    #expect(deleted.reminderCount == 0)
    #expect(await repository.createListCallCount == 1)
    #expect(await repository.updateListCallCount == 1)
    #expect(await repository.deleteListCallCount == 1)
  }

  @Test("requires the separate list-delete gate before repository delegation")
  func requiresTheSeparateDeleteGate() async {
    let repository = MutableReminderRepository(
      lists: [ReminderList(id: Self.sourceListID, name: "Source")]
    )
    let service = ReminderToolService(
      repository: repository,
      policy: .init(mutationMode: .allowed, listDeleteEnabled: false)
    )

    await #expect(throws: ReminderError.self) {
      try await service.deleteList(id: Self.sourceListID, idempotencyKey: "list-delete-blocked")
    }
    #expect(await repository.deleteListCallCount == 0)
  }

  @Test("refuses to delete a non-empty list without deleting its Reminder")
  func refusesNonEmptyListDeletion() async {
    let repository = MutableReminderRepository(
      lists: [ReminderList(id: Self.occupiedListID, name: "Occupied")],
      reminders: [Self.occupiedReminder]
    )
    let service = ReminderToolService(
      repository: repository,
      policy: .init(mutationMode: .allowed, listDeleteEnabled: true)
    )

    await #expect(throws: ReminderError.self) {
      try await service.deleteList(id: Self.occupiedListID, idempotencyKey: "delete-non-empty")
    }
    #expect(await repository.deleteListCallCount == 1)
    let remaining = try? await repository.getReminder(id: Self.occupiedReminder.id)
    #expect(remaining == Self.occupiedReminder)
  }
}

@Suite("Reminder lifecycle MCP contract")
struct ReminderLifecycleMCPContractTests {
  @Test("discovers and routes the policy-controlled Reminder lifecycle")
  func discoversAndRoutesLifecycleTools() async throws {
    let listID = ReminderReferenceCodec.list(calendarIdentifier: "mcp-mutable-calendar")
    let repository = MutableReminderRepository(
      lists: [ReminderList(id: listID, name: "MCP fixture")]
    )
    let reminderService = ReminderToolService(
      repository: repository,
      policy: .init(mutationMode: .allowed)
    )
    let server = await ApplePlatformMCPServer(
      service: MailToolService(repository: LifecycleEmptyMailRepository()),
      reminderService: reminderService
    ).makeServer()
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let serverTask = Task {
      try await server.start(transport: serverTransport)
      await server.waitUntilCompleted()
    }
    let client = Client(name: "reminder-lifecycle-contract", version: "1.0.0")

    _ = try await client.connect(transport: clientTransport)
    let listed = try await client.listTools()
    let names = Set(listed.tools.map(\.name))
    #expect(names.isSuperset(of: [
      "reminder_create_reminder",
      "reminder_update_reminder",
      "reminder_complete_reminder",
      "reminder_delete_reminder",
    ]))

    let createTool = try #require(
      listed.tools.first(where: { $0.name == "reminder_create_reminder" }))
    let createSchema = try #require(createTool.inputSchema.objectValue)
    #expect(createSchema["additionalProperties"]?.boolValue == false)
    #expect(
      createSchema["required"]?.arrayValue?.compactMap(\.stringValue)
        == ["list_id", "title", "idempotency_key"])

    let updateTool = try #require(
      listed.tools.first(where: { $0.name == "reminder_update_reminder" }))
    let updateSchema = try #require(updateTool.inputSchema.objectValue)
    #expect(
      updateSchema["required"]?.arrayValue?.compactMap(\.stringValue)
        == ["reminder_id", "idempotency_key"])

    let create = try await client.callTool(
      name: "reminder_create_reminder",
      arguments: [
        "list_id": .string(listID.opaqueValue),
        "title": .string("MCP lifecycle fixture"),
        "notes": .string("initial note"),
        "priority": .int(5),
        "idempotency_key": .string("mcp-create"),
      ]
    )
    #expect(create.isError == false)
    #expect(lifecycleText(create.content).contains("MCP lifecycle fixture"))
    let reminderID = await repository.latestCreatedID!

    let update = try await client.callTool(
      name: "reminder_update_reminder",
      arguments: [
        "reminder_id": .string(reminderID.opaqueValue),
        "title": .string("MCP lifecycle updated"),
        "notes": .null,
        "idempotency_key": .string("mcp-update"),
      ]
    )
    #expect(update.isError == false)
    #expect(lifecycleText(update.content).contains("MCP lifecycle updated"))

    let complete = try await client.callTool(
      name: "reminder_complete_reminder",
      arguments: [
        "reminder_id": .string(reminderID.opaqueValue),
        "idempotency_key": .string("mcp-complete"),
      ]
    )
    #expect(complete.isError == false)
    #expect(lifecycleText(complete.content).contains("\"completed\":true"))

    let delete = try await client.callTool(
      name: "reminder_delete_reminder",
      arguments: [
        "reminder_id": .string(reminderID.opaqueValue),
        "idempotency_key": .string("mcp-delete"),
      ]
    )
    #expect(delete.isError == false)
    #expect(lifecycleText(delete.content).contains("\"deleted\":true"))

    await client.disconnect()
    await serverTransport.disconnect()
    _ = try await serverTask.value
  }

  private func lifecycleText(_ content: [Tool.Content]) -> String {
    content.compactMap { content in
      guard case .text(let value, _, _) = content else { return nil }
      return value
    }.joined()
  }
}

@Suite("Reminder list lifecycle MCP contract")
struct ReminderListLifecycleMCPContractTests {
  @Test("discovers and routes the explicit-source list lifecycle")
  func discoversAndRoutesListLifecycleTools() async throws {
    let sourceListID = ReminderReferenceCodec.list(calendarIdentifier: "mcp-list-source")
    let repository = MutableReminderRepository(
      lists: [ReminderList(id: sourceListID, name: "MCP source")]
    )
    let reminderService = ReminderToolService(
      repository: repository,
      policy: .init(mutationMode: .allowed, listDeleteEnabled: true)
    )
    let server = await ApplePlatformMCPServer(
      service: MailToolService(repository: LifecycleEmptyMailRepository()),
      reminderService: reminderService
    ).makeServer()
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let serverTask = Task {
      try await server.start(transport: serverTransport)
      await server.waitUntilCompleted()
    }
    let client = Client(name: "reminder-list-lifecycle-contract", version: "1.0.0")

    _ = try await client.connect(transport: clientTransport)
    let listed = try await client.listTools()
    let names = Set(listed.tools.map(\.name))
    #expect(names.isSuperset(of: [
      "reminder_create_list",
      "reminder_update_list",
      "reminder_delete_list",
    ]))

    let createTool = try #require(listed.tools.first(where: { $0.name == "reminder_create_list" }))
    let createSchema = try #require(createTool.inputSchema.objectValue)
    #expect(
      createSchema["required"]?.arrayValue?.compactMap(\.stringValue)
        == ["source_list_id", "name", "idempotency_key"])

    let created = try await client.callTool(
      name: "reminder_create_list",
      arguments: [
        "source_list_id": .string(sourceListID.opaqueValue),
        "name": .string("MCP isolated list"),
        "idempotency_key": .string("mcp-list-create"),
      ]
    )
    #expect(created.isError == false)
    let createdListID = await repository.latestCreatedListID!

    let updated = try await client.callTool(
      name: "reminder_update_list",
      arguments: [
        "list_id": .string(createdListID.opaqueValue),
        "name": .string("MCP renamed list"),
        "idempotency_key": .string("mcp-list-update"),
      ]
    )
    #expect(updated.isError == false)

    let deleted = try await client.callTool(
      name: "reminder_delete_list",
      arguments: [
        "list_id": .string(createdListID.opaqueValue),
        "idempotency_key": .string("mcp-list-delete"),
      ]
    )
    #expect(deleted.isError == false)

    await client.disconnect()
    await serverTransport.disconnect()
    _ = try await serverTask.value
  }
}

private actor MutableReminderRepository: ReminderRepository {
  private var status: ReminderAuthorizationStatus
  private var lists: [ReminderList]
  private var reminders: [ReminderItem]
  private var nextItemNumber = 1

  private(set) var createCallCount = 0
  private(set) var updateCallCount = 0
  private(set) var completeCallCount = 0
  private(set) var deleteCallCount = 0
  private(set) var createListCallCount = 0
  private(set) var updateListCallCount = 0
  private(set) var deleteListCallCount = 0
  private(set) var latestCreatedID: ReminderReference?
  private(set) var latestCreatedListID: ReminderListReference?
  private var nextListNumber = 1

  init(
    status: ReminderAuthorizationStatus = .fullAccess,
    lists: [ReminderList],
    reminders: [ReminderItem] = []
  ) {
    self.status = status
    self.lists = lists
    self.reminders = reminders
  }

  func authorizationStatus() async -> ReminderAuthorizationStatus { status }

  func requestFullAccess() async throws -> ReminderAuthorizationStatus {
    status = .fullAccess
    return status
  }

  func listLists() async throws -> [ReminderList] { lists }

  func listReminders(listID: ReminderListReference) async throws -> [ReminderItem] {
    guard lists.contains(where: { $0.id == listID }) else {
      throw ReminderError.listNotFound
    }
    return reminders.filter { $0.listID == listID }
  }

  func getReminder(id: ReminderReference) async throws -> ReminderItem {
    guard let reminder = reminders.first(where: { $0.id == id }) else {
      throw ReminderError.reminderNotFound
    }
    return reminder
  }

  func createReminder(_ request: ReminderCreateRequest) async throws -> ReminderItem {
    createCallCount += 1
    guard lists.contains(where: { $0.id == request.listID }) else {
      throw ReminderError.listNotFound
    }
    let item = ReminderItem(
      id: ReminderReferenceCodec.reminder(
        calendarIdentifier: "mutable-calendar",
        calendarItemIdentifier: "created-\(nextItemNumber)"
      ),
      listID: request.listID,
      title: request.title,
      notes: request.notes,
      priority: request.priority,
      completed: false
    )
    nextItemNumber += 1
    reminders.append(item)
    latestCreatedID = item.id
    return item
  }

  func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderItem {
    updateCallCount += 1
    guard let index = reminders.firstIndex(where: { $0.id == request.id }) else {
      throw ReminderError.reminderNotFound
    }
    let current = reminders[index]
    let listID: ReminderListReference
    switch request.listID {
    case .unchanged: listID = current.listID
    case .set(let value):
      guard lists.contains(where: { $0.id == value }) else { throw ReminderError.listNotFound }
      listID = value
    case .clear: throw ReminderError.invalidInput("list_id cannot be cleared")
    }
    let title: String
    switch request.title {
    case .unchanged: title = current.title
    case .set(let value): title = value
    case .clear: throw ReminderError.invalidInput("title cannot be cleared")
    }
    let notes: String?
    switch request.notes {
    case .unchanged: notes = current.notes
    case .set(let value): notes = value
    case .clear: notes = nil
    }
    let priority: Int
    switch request.priority {
    case .unchanged: priority = current.priority
    case .set(let value): priority = value
    case .clear: throw ReminderError.invalidInput("priority cannot be cleared")
    }

    let updated = ReminderItem(
      id: current.id,
      listID: listID,
      title: title,
      notes: notes,
      priority: priority,
      completed: current.completed,
      completionDate: current.completionDate,
      due: current.due,
      recurrence: current.recurrence
    )
    reminders[index] = updated
    return updated
  }

  func completeReminder(id: ReminderReference) async throws -> ReminderItem {
    completeCallCount += 1
    guard let index = reminders.firstIndex(where: { $0.id == id }) else {
      throw ReminderError.reminderNotFound
    }
    let current = reminders[index]
    guard !current.completed else { return current }
    let completed = ReminderItem(
      id: current.id,
      listID: current.listID,
      title: current.title,
      notes: current.notes,
      priority: current.priority,
      completed: true,
      completionDate: Date(timeIntervalSince1970: 1_760_000_000),
      due: current.due,
      recurrence: current.recurrence
    )
    reminders[index] = completed
    return completed
  }

  func deleteReminder(id: ReminderReference) async throws -> ReminderDeleteResult {
    deleteCallCount += 1
    guard let index = reminders.firstIndex(where: { $0.id == id }) else {
      throw ReminderError.reminderNotFound
    }
    reminders.remove(at: index)
    return ReminderDeleteResult(id: id, deleted: true)
  }

  func createList(_ request: ReminderListCreateRequest) async throws -> ReminderList {
    createListCallCount += 1
    guard let source = lists.first(where: { $0.id == request.sourceListID }) else {
      throw ReminderError.listNotFound
    }
    let created = ReminderList(
      id: ReminderReferenceCodec.list(calendarIdentifier: "created-list-\(nextListNumber)"),
      name: request.name,
      sourceName: source.sourceName,
      capabilities: .init(canRead: true, canWrite: true)
    )
    nextListNumber += 1
    lists.append(created)
    latestCreatedListID = created.id
    return created
  }

  func updateList(_ request: ReminderListUpdateRequest) async throws -> ReminderList {
    updateListCallCount += 1
    guard let index = lists.firstIndex(where: { $0.id == request.id }) else {
      throw ReminderError.listNotFound
    }
    let current = lists[index]
    let updated = ReminderList(
      id: current.id,
      name: request.name,
      sourceName: current.sourceName,
      capabilities: current.capabilities
    )
    lists[index] = updated
    return updated
  }

  func deleteList(id: ReminderListReference) async throws -> ReminderListDeleteResult {
    deleteListCallCount += 1
    guard let index = lists.firstIndex(where: { $0.id == id }) else {
      throw ReminderError.listNotFound
    }
    let reminderCount = reminders.filter { $0.listID == id }.count
    guard reminderCount == 0 else { throw ReminderError.listNotEmpty }
    lists.remove(at: index)
    return ReminderListDeleteResult(id: id, deleted: true, reminderCount: reminderCount)
  }
}

private actor LifecycleEmptyMailRepository: MailRepository {
  func listAccounts(includeDisabled: Bool) async throws -> [MailAccountModel] { [] }
  func listMailboxes(accountID: AccountReference, includeCounts: Bool) async throws -> [Mailbox] { [] }
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
  func updateMessage(_ request: MailMessageUpdateRequest) async throws -> MailMessageMutationResult {
    throw MailError.unsupportedByAccount
  }
}
