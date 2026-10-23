import Foundation
import MCP
import Testing

#if !XCODE_COMBINED_TEST_TARGET
  @testable import ApplePlatformMCPKit
#endif

private actor ContactsFixture: ContactsRepository {
  var access: ContactsAccess
  var reads = 0
  var lastQuery: ContactsQuery?
  init(_ access: ContactsAccess = .authorized) { self.access = access }
  func authorizationStatus() -> ContactsAccess { access }
  func listContainers(maximum: Int) throws -> ContactsPage<ContactsContainer> {
    reads += 1
    return .init(
      items: [
        .init(
          id: try ContactsReferenceCodec.encode(container: "c"), name: "Synthetic",
          provider_type: "local")
      ], authorization: access, visibility: "authorized_subset", truncated: false,
      scan_complete: true, records_examined: 1, limit: maximum)
  }
  func search(_ q: ContactsQuery, maximumScan: Int) throws -> ContactsPage<ContactsSummary> {
    reads += 1
    lastQuery = q
    let base = try ContactsReferenceCodec.encode(container: "c")
    let values = try ["one", "two"].prefix(q.limit).map { n in
      ContactsSummary(
        id: try ContactsReferenceCodec.encode(container: "c", record: n), container_id: base,
        kind: "person", given_name: "Änne", family_name: "Müller", organization: "Example",
        truncated: false)
    }
    return .init(
      items: values, authorization: access, visibility: "authorized_subset", truncated: q.limit < 2,
      scan_complete: q.limit >= 2, records_examined: 2, limit: q.limit)
  }
  func get(id: String) throws -> ContactsRecord {
    reads += 1
    let a = try ContactsReferenceCodec.decode(id, record: true)
    guard a.container == "c", a.record == "one" else { throw ContactsError("contactsNotFound") }
    return .init(
      summary: .init(
        id: id, container_id: try ContactsReferenceCodec.encode(container: "c"), kind: "person",
        given_name: "Änne", family_name: "Müller", organization: "Example", truncated: false),
      middle_name: "", name_prefix: "", name_suffix: "",
      emails: [
        .init(label: "work", value: "one@example.invalid"),
        .init(label: "home", value: "two@example.invalid"),
      ], phones: [.init(label: "work", value: "+49 (30) 1234")], truncated: false)
  }
}
@Suite("Contacts references, privacy and matching")
struct ContactsDomainTests {
  @Test func canonicalContainerScopedIndividualReferences() throws {
    let id = try ContactsReferenceCodec.encode(container: "c", record: "one")
    for _ in 0..<32 {
      #expect(try ContactsReferenceCodec.encode(container: "c", record: "one") == id)
    }
    #expect(try ContactsReferenceCodec.decode(id, record: true).record == "one")
    #expect(throws: ContactsError.self) { try ContactsReferenceCodec.decode(id, record: false) }
    #expect(throws: ContactsError.self) {
      try ContactsReferenceCodec.decode("cal_v1_bad", record: true)
    }
    let noncanonical =
      "contacts_v1_"
      + Data(#"{"version":1,"kind":"record","container":"c","record":"one","extra":true}"#.utf8)
      .base64EncodedString()
    #expect(throws: ContactsError.self) {
      try ContactsReferenceCodec.decode(noncanonical, record: true)
    }
    #expect(try ContactsReferenceCodec.encode(container: "other", record: "one") != id)
  }
  @Test func unicodeCompanyEmailPhoneMatchingNeverAddsCountryCode() {
    func match(_ q: String, _ f: [ContactsField]) -> Bool {
      ContactsQuery(query: q, fields: f, containerIDs: nil, limit: 1).matches(
        names: ["", "Änne", "", "Müller", ""], company: "Müller GmbH",
        emails: ["ANNE@example.invalid"], phones: ["030 1234"])
    }
    #expect(match("anne muller", [.name]))
    #expect(match("muller gmbh", [.company]))
    #expect(match("anne@EXAMPLE", [.email]))
    #expect(match("(030) 12", [.phone]))
    #expect(!match("+49 30 12", [.phone]))
    #expect(!match("---", [.phone]))
    #expect(!match("example", [.name]))
  }
  @Test func authorizationStatesNeverImplicitlyReadOrPrompt() async throws {
    for raw in [0, 1, 2, 99] {
      let repo = ContactsFixture(ContactsAccess.normalized(raw))
      let service = ContactsToolService(repository: repo)
      await #expect(throws: ContactsError.self) { try await service.list() }
      #expect(await repo.reads == 0)
    }
    for access in [ContactsAccess.authorized, .limited] {
      let service = ContactsToolService(repository: ContactsFixture(access))
      #expect(try await service.list().authorization == access)
    }
    #expect(try ApplePlatformMCPCommand.parse(["doctor", "--request-contacts"]) == .doctorContacts)
    #expect(ContactsAccess.normalized(4) == .limited)
  }
  @Test func strictInputsFailBeforeRepositoryAccess() async throws {
    let repo = ContactsFixture()
    let service = ContactsToolService(repository: repo)
    for a: [String: Value] in [
      [:], ["query": .string("")], ["query": .string("a")], ["query": .string("  ")],
      ["query": .string(String(repeating: "a", count: 257))], ["query": .string("a\nb")],
      ["query": .string("ok"), "limit": .bool(true)],
      ["query": .string("ok"), "limit": .double(2)], ["query": .string("ok"), "limit": .int(0)],
      ["query": .string("ok"), "fields": .array([])],
      ["query": .string("ok"), "fields": .array([.string("note")])],
      ["query": .string("ok"), "fields": .array([.string("name"), .string("name")])],
      ["query": .string("ok"), "container_ids": .array([])],
      ["query": .string("ok"), "container_ids": .array([.string("stale")])],
      ["query": .string("ok"), "extra": .bool(true)],
    ] {
      await #expect(throws: ContactsError.self) {
        try await ContactsMCPTools.call("contacts_search_contacts", arguments: a, service: service)
      }
    }
    await #expect(throws: ContactsError.self) { try await service.get(id: "raw") }
    #expect(await repo.reads == 0)
  }
  @Test func minimalSummariesPreserveDuplicatesAndClampLimit() async throws {
    let repo = ContactsFixture()
    let service = ContactsToolService(repository: repo, maxResults: 1)
    let p = try await service.search(query: "  muller  ", fields: [.name], ids: nil, limit: 1000)
    #expect(p.limit == 1 && p.truncated && !p.scan_complete)
    #expect(await repo.lastQuery?.query == "muller")
    let full = try await ContactsToolService(repository: repo).search(
      query: "muller", fields: [.name], ids: nil, limit: nil)
    #expect(full.items.count == 2 && full.items[0].id != full.items[1].id)
    let json = String(decoding: try JSONEncoder().encode(full), as: UTF8.self)
    #expect(!json.contains("emails") && !json.contains("phones") && !json.contains("note"))
    let c = try await service.get(id: ContactsReferenceCodec.encode(container: "c", record: "one"))
    #expect(c.contact.emails.count == 2 && c.contact.phones.count == 1)
    #expect(c.contact.phones[0].value == "+49 (30) 1234")
    let stale = try ContactsReferenceCodec.encode(container: "c", record: "missing")
    await #expect(throws: ContactsError("contactsNotFound")) { try await service.get(id: stale) }
  }
  @Test func catalogIsStrictAndExclusivelyReadOnly() throws {
    #expect(ContactsMCPTools.tools.count == 3)
    for tool in ContactsMCPTools.tools {
      #expect(tool.annotations.readOnlyHint == true)
      #expect(tool.annotations.destructiveHint == false)
      #expect(tool.inputSchema.objectValue?["additionalProperties"]?.boolValue == false)
    }
  }
  @Test func inMemoryProtocolRoutesAllReadsAndRefusesWrites() async throws {
    let server = await ApplePlatformMCPServer(
      service: MailToolService(repository: ContactsEmptyMailRepository()),
      contactsService: .init(repository: ContactsFixture())
    ).makeServer()
    let (ct, st) = await InMemoryTransport.createConnectedPair()
    let task = Task { try await server.start(transport: st) }
    let client = Client(name: "contacts-test", version: "1")
    _ = try await client.connect(transport: ct)
    #expect(try await client.listTools().tools.filter { $0.name.hasPrefix("contacts_") }.count == 3)
    #expect(try await client.callTool(name: "contacts_list_containers").isError != true)
    #expect(
      try await client.callTool(
        name: "contacts_search_contacts", arguments: ["query": .string("muller")]
      ).isError != true)
    #expect(
      try await client.callTool(
        name: "contacts_get_contact",
        arguments: [
          "contact_id": .string(ContactsReferenceCodec.encode(container: "c", record: "one"))
        ]
      ).isError != true)
    #expect(
      try await client.callTool(name: "contacts_create_contact", arguments: [:]).isError == true)
    await client.disconnect()
    await server.stop()
    _ = try await task.value
  }
  @Test func nativeHTTPCallsAllThreeReadsAndValidates() async throws {
    let server = await ApplePlatformMCPServer(
      service: MailToolService(repository: ContactsEmptyMailRepository()),
      contactsService: .init(repository: ContactsFixture())
    ).makeServer()
    let runtime = ApplePlatformMCPStreamableHTTPRuntime(server: server, readinessProbe: { true })
    try await runtime.start()
    func call(_ method: String, _ params: [String: Any], id: Int) async throws -> [String: Any] {
      let body = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": id, "method": method, "params": params,
      ])
      let response = await runtime.handle(
        .init(
          method: "POST",
          headers: [
            "Accept": "application/json", "Content-Type": "application/json",
            "MCP-Protocol-Version": "2025-06-18",
          ], body: body, path: "/mcp"))
      #expect(response.statusCode == 200)
      let responseBody = try #require(response.bodyData)
      return try #require(JSONSerialization.jsonObject(with: responseBody) as? [String: Any])
    }
    _ = try await call(
      "initialize",
      [
        "protocolVersion": "2025-06-18", "capabilities": [:],
        "clientInfo": ["name": "contacts-http", "version": "1"],
      ], id: 1)
    for (i, name) in ContactsMCPTools.tools.map(\.name).enumerated() {
      let a: [String: Any] =
        name == "contacts_search_contacts"
        ? ["query": "muller"]
        : name == "contacts_get_contact"
          ? ["contact_id": try ContactsReferenceCodec.encode(container: "c", record: "one")] : [:]
      let json = try await call("tools/call", ["name": name, "arguments": a], id: i + 2)
      #expect((json["result"] as? [String: Any])?["isError"] as? Bool != true)
    }
    let invalid = try await call(
      "tools/call", ["name": "contacts_list_containers", "arguments": ["extra": true]], id: 10)
    #expect((invalid["result"] as? [String: Any])?["isError"] as? Bool == true)
    await runtime.stop()
  }
}

private actor ContactsEmptyMailRepository: MailRepository {
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
