import Foundation
import MCP
import Testing

#if !XCODE_COMBINED_TEST_TARGET
  @testable import ApplePlatformMCPKit
#endif

@Suite("Notes")
struct NotesTests {
  @Test func referencesRemainCanonicalAndAcceptExistingEncoding() throws {
    let canonical =
      "notes_v1_"
      + Data(#"{"ids":["account","folder"],"kind":"folder","version":1}"#.utf8)
      .base64EncodedString()
    for _ in 0..<32 {
      #expect(try NotesReference.make("folder", ["account", "folder"]) == canonical)
    }
    let prior =
      "notes_v1_"
      + Data(#"{"version":1,"kind":"folder","ids":["account","folder"]}"#.utf8)
      .base64EncodedString()
    #expect(try NotesReference.decode(prior, kind: "folder", count: 2) == ["account", "folder"])
  }
  @Test func searchAndReadReturnTheSameOpaqueReference() async throws {
    let service = NotesToolService(repository: FakeNotesRepository())
    let folder = try NotesReference.make("folder", ["account", "folder"])
    let page = try await service.search(folderID: folder)
    let found = try #require(page.items.first)
    let read = try await service.get(noteID: found.id)
    #expect(read.id == found.id)
  }
  @Test func explicitPermissionSetupCommand() throws {
    #expect(try ApplePlatformMCPCommand.parse(["doctor", "--request-notes"]) == .doctorNotes)
  }
  @Test func configurationDefaultsAndIndependentGate() throws {
    let defaults = try JSONDecoder().decode(MailServerConfiguration.self, from: Data("{}".utf8))
    #expect(defaults.notesMutationMode == .denied)
    let config = try JSONDecoder().decode(
      MailServerConfiguration.self,
      from: Data(#"{"mutation_mode":"allowed","notes_mutation_mode":"confirmation_required"}"#.utf8)
    )
    #expect(config.notesMutationMode == .confirmationRequired)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(
        MailServerConfiguration.self, from: Data(#"{"notes_mutation_mode":"typo"}"#.utf8))
    }
  }
  @Test func scopedReferencesAndLimits() async throws {
    let repository = FakeNotesRepository()
    let service = NotesToolService(repository: repository, maxResults: 2, maxBodyBytes: 5)
    let account = try #require(try await service.accounts().first)
    let folder = try #require(try await service.folders(accountID: account.id).first)
    let page = try await service.search(folderID: folder.id, limit: 100)
    let item = try #require(page.items.first)
    #expect(
      try NotesReference.decode(item.id, kind: "note", count: 3) == ["account", "folder", "note"])
    let note = try await service.get(noteID: item.id)
    #expect(note.text == "äö")
    #expect(note.truncated)
    #expect(await repository.lastLimit == 2)
    await #expect(throws: NotesError.self) { try await service.get(noteID: folder.id) }
    await #expect(throws: NotesError.self) {
      try await service.search(folderID: folder.id, limit: 0)
    }
  }
  @Test func writesDeniedBeforeBackendAccess() async throws {
    let repository = FakeNotesRepository()
    for mode in [ReminderMutationMode.denied, .confirmationRequired] {
      let service = NotesToolService(repository: repository, mutationMode: mode)
      await #expect(throws: NotesError.self) {
        try await service.create(folderID: "invalid", title: "Title", text: "", key: "key")
      }
    }
    #expect(await repository.creates == 0)
  }
  @Test func concurrentCreateRetriesAndConflicts() async throws {
    let repository = FakeNotesRepository()
    let service = NotesToolService(repository: repository, mutationMode: .allowed)
    let folder = try NotesReference.make("folder", ["account", "folder"])
    async let first = service.create(
      folderID: folder, title: "A <title>", text: "&\n<script>", key: "one")
    async let retry = service.create(
      folderID: folder, title: "A <title>", text: "&\n<script>", key: "one")
    let results = try await [first, retry]
    #expect(results[0] == results[1])
    #expect(await repository.creates == 1)
    #expect(
      await repository.lastHTML
        == "<div><b>A &lt;title&gt;</b></div><div>&amp;<br>&lt;script&gt;</div>")
    await #expect(throws: NotesError.self) {
      try await service.create(folderID: folder, title: "Changed", text: "", key: "one")
    }
    #expect(await repository.creates == 1)
  }
  @Test func ambiguousFailureDoesNotWriteAgain() async throws {
    let repository = FakeNotesRepository(failCreate: true)
    let service = NotesToolService(repository: repository, mutationMode: .allowed)
    let folder = try NotesReference.make("folder", ["account", "folder"])
    for _ in 0..<2 {
      do {
        _ = try await service.create(folderID: folder, title: "Title", text: "Body", key: "unknown")
        Issue.record("Expected an ambiguous outcome")
      } catch let error as NotesError { #expect(error.code == "notesCreationOutcomeUnknown") }
    }
    #expect(await repository.creates == 1)
  }
  @Test func lockedNotesAreRefused() async throws {
    let service = NotesToolService(repository: FakeNotesRepository(locked: true))
    let id = try NotesReference.make("note", ["account", "folder", "note"])
    await #expect(throws: NotesError.self) { try await service.get(noteID: id) }
  }
  @Test func catalogAndRouting() async throws {
    let service = NotesToolService(repository: FakeNotesRepository())
    let server = await ApplePlatformMCPServer(
      service: MailToolService(repository: NotesEmptyMailRepository()), notesService: service
    ).makeServer()
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let serverTask = Task { try await server.start(transport: serverTransport) }
    let client = Client(name: "notes-tests", version: "1.0")
    _ = try await client.connect(transport: clientTransport)
    let tools = try await client.listTools()
    #expect(tools.tools.filter { $0.name.hasPrefix("notes_") }.count == 5)
    let valid = try await client.callTool(name: "notes_list_accounts")
    #expect(valid.isError != true)
    let invalid = try await client.callTool(
      name: "notes_search_notes", arguments: ["folder_id": .int(1)])
    #expect(invalid.isError == true)
    let folder = try NotesReference.make("folder", ["account", "folder"])
    let badLimit = try await client.callTool(
      name: "notes_search_notes", arguments: ["folder_id": .string(folder), "limit": .string("2")])
    #expect(badLimit.isError == true)
    let denied = try await client.callTool(
      name: "notes_create_note",
      arguments: [
        "folder_id": .string(folder), "title": .string("test"), "text": .string(""),
        "idempotency_key": .string("key"),
      ])
    #expect(denied.isError == true)
    await client.disconnect()
    await server.stop()
    _ = try await serverTask.value
  }
}

private actor FakeNotesRepository: NotesRepository {
  var creates = 0
  var lastLimit = 0
  var lastHTML = ""
  let failCreate: Bool
  let locked: Bool
  init(failCreate: Bool = false, locked: Bool = false) {
    self.failCreate = failCreate
    self.locked = locked
  }
  func accounts() async throws -> [NotesContainer] { [NotesContainer(id: "account", name: "Test")] }
  func folders(account: String) async throws -> [NotesContainer] {
    #expect(account == "account")
    return [NotesContainer(id: "folder", name: "Folder")]
  }
  func search(account: String, folder: String, query: String, limit: Int) async throws -> NotesPage
  {
    #expect(account == "account" && folder == "folder")
    lastLimit = limit
    return NotesPage(items: [NotesItem(id: "note", name: "Title")], truncated: true)
  }
  func get(account: String, folder: String, note: String) async throws -> NotesItem {
    #expect(account == "account" && folder == "folder" && note == "note")
    return NotesItem(id: "note", name: "Title", locked: locked, text: "äöü more")
  }
  func create(account: String, folder: String, html: String) async throws -> NotesItem {
    creates += 1
    lastHTML = html
    try await Task.sleep(for: .milliseconds(10))
    if failCreate { throw NotesError("notesAutomationFailed") }
    return NotesItem(id: "new-note", name: "Title")
  }
}

private actor NotesEmptyMailRepository: MailRepository {
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
