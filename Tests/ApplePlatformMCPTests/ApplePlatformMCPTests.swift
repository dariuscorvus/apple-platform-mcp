import ApplePlatformMCPKit
import Foundation
import MCP
import Testing

@Suite("Reference codec")
struct ReferenceCodecTests {
  @Test("encodes versioned opaque account references")
  func accountReferenceRoundTrip() throws {
    let reference = ReferenceCodec.account(rawID: "account-secret-id")

    #expect(reference.version == 1)
    #expect(reference.opaqueValue.hasPrefix("r1_"))
    #expect(!reference.opaqueValue.contains("account-secret-id"))
    #expect(ReferenceCodec.decode(reference)?["id"] == "account-secret-id")
  }

  @Test("keeps mailbox context in the reference")
  func mailboxReferenceRoundTrip() throws {
    let reference = ReferenceCodec.mailbox(accountRawID: "a-1", path: ["Inbox", "Receipts"])
    let decoded = ReferenceCodec.decode(reference)

    #expect(decoded?["account"] == "a-1")
    #expect(decoded?["path"] == "Inbox\u{1F}Receipts")
  }

  @Test("rejects unsupported reference versions")
  func rejectsUnsupportedVersion() {
    let reference = ReferenceCodec.account(rawID: "account-secret-id")
    let unsupported = AccountReference(version: 2, opaqueValue: reference.opaqueValue)

    #expect(ReferenceCodec.decode(unsupported) == nil)
  }

  @Test("encodes references as MCP-safe strings")
  func encodesReferencesAsStrings() throws {
    let reference = ReferenceCodec.account(rawID: "account-secret-id")
    let data = try JSONEncoder().encode(reference)
    let decoded = try JSONDecoder().decode(AccountReference.self, from: data)

    #expect(String(data: data, encoding: .utf8)?.hasPrefix("\"r1_") == true)
    #expect(decoded.version == reference.version)
    #expect(decoded.opaqueValue == reference.opaqueValue)
  }
}

@Suite("Mail content")
struct MailContentSanitizerTests {
  @Test("removes active HTML and remote resources")
  func sanitizesHTML() {
    let source = """
      Message-ID: <one@example.com>
      Content-Type: text/html

      <p>Hello</p><script>sendSecrets()</script><img src="https://tracker.invalid/pixel"><a href="javascript:sendSecrets()">link</a>
      """

    let body = MailContentSanitizer.body(from: source, format: .both, maxBytes: 1_000)

    #expect(body.sanitizedHTML?.contains("sendSecrets") == false)
    #expect(body.sanitizedHTML?.contains("https://tracker.invalid") == false)
    #expect(body.sanitizedHTML?.contains("javascript:") == false)
    #expect(body.plainText?.contains("Hello") == true)
  }

  @Test("marks truncated content and preserves headers")
  func truncatesBody() {
    let source = "Message-ID: <one@example.com>\n\n1234567890"
    let parsed = MailContentSanitizer.parseSource(source)
    let body = MailContentSanitizer.body(from: source, format: .plainText, maxBytes: 4)

    #expect(parsed.headers["message-id"] == "<one@example.com>")
    #expect(body.truncated)
    #expect(body.originalByteCount == 10)
    #expect(body.plainText == "1234")
  }

  @Test("normalizes a multipart alternative body")
  func normalizesMultipartBody() {
    let source = """
      Content-Type: multipart/alternative; boundary="fixture-boundary"

      --fixture-boundary
      Content-Type: text/plain; charset=utf-8
      Content-Transfer-Encoding: quoted-printable

      Hello=20fixture
      --fixture-boundary
      Content-Type: text/html; charset=utf-8

      <p>Hello <strong>fixture</strong></p><img src="https://tracker.invalid/pixel">
      --fixture-boundary--
      """

    let body = MailContentSanitizer.body(from: source, format: .both, maxBytes: 1_000)

    #expect(body.plainText == "Hello fixture")
    #expect(body.sanitizedHTML?.contains("<strong>fixture</strong>") == true)
    #expect(body.sanitizedHTML?.contains("tracker.invalid") == false)
  }
}

@Suite("Search cursors")
struct SearchCursorTests {
  @Test("round-trips a cursor for the same query")
  func cursorRoundTrip() throws {
    let query = MailSearchQuery(subject: "invoice", limit: 20)
    let cursor = SearchCursorCodec.encode(query: query, offset: 20)

    #expect(cursor.hasPrefix("c1_"))
    #expect(try SearchCursorCodec.decode(cursor, query: query) == 20)
  }

  @Test("rejects a cursor for a different query")
  func rejectsMismatchedCursor() {
    let cursor = SearchCursorCodec.encode(
      query: MailSearchQuery(subject: "invoice", limit: 20),
      offset: 20
    )

    #expect(throws: MailError.self) {
      try SearchCursorCodec.decode(
        cursor,
        query: MailSearchQuery(subject: "receipt", limit: 20)
      )
    }
  }
}

@Suite("Read-only policy")
struct MailPolicyTests {
  @Test("caps client result limits")
  func capsResults() throws {
    let policy = MailPolicy(maxResults: 50)
    #expect(try policy.boundedLimit(100) == 50)
    #expect(try policy.boundedLimit(nil) == 20)
  }

  @Test("rejects non-positive result limits")
  func rejectsInvalidLimit() {
    #expect(throws: MailError.self) {
      try MailPolicy().boundedLimit(0)
    }
  }
}

@Suite("Configuration")
struct ConfigurationTests {
  @Test("defaults to bounded read-only policy")
  func defaultsToReadOnly() {
    let configuration = MailServerConfiguration(maxResults: 0, maxBodyBytes: 0)

    #expect(configuration.mode == .readOnly)
    #expect(configuration.policy.maxResults == 1)
    #expect(configuration.policy.maxBodyBytes == 1)
  }

  @Test("rejects unsupported write mode")
  func rejectsWriteMode() {
    let data = Data(#"{"mode":"write"}"#.utf8)

    #expect(throws: MailError.self) {
      try JSONDecoder().decode(MailServerConfiguration.self, from: data)
    }
  }

  @Test("decodes opaque string allowlists")
  func decodesOpaqueStringAllowlists() throws {
    let account = ReferenceCodec.account(rawID: "account-1")
    let json = """
      {"allowed_account_ids":["\(account.opaqueValue)"]}
      """

    let configuration = try JSONDecoder().decode(
      MailServerConfiguration.self,
      from: Data(json.utf8)
    )

    #expect(configuration.allowedAccountIDs == Set([account]))
  }
}

@Suite("Permission contract")
struct PermissionContractTests {
  @Test("permission failures provide a safe recovery path")
  func permissionFailureIsRecoverable() {
    #expect(MailError.permissionDenied.recovery != nil)
    #expect(MailError.permissionDenied.errorDescription?.contains("permission") == true)
  }
}

@Suite("Tool catalog")
struct MCPToolCatalogTests {
  @Test("exposes only read-only tools")
  func readOnlyTools() {
    let names = Set(MCPToolCatalog.tools.map(\.name))
    #expect(
      names == [
        "mail_server_info",
        "mail_list_accounts",
        "mail_list_mailboxes",
        "mail_search_messages",
        "mail_get_message",
      ])
    #expect(MCPToolCatalog.tools.allSatisfy { $0.annotations.readOnlyHint == true })
  }
}

@Suite("Server command")
struct ApplePlatformMCPCommandTests {
  @Test("defaults to the stdio server for backward compatibility")
  func defaultsToStdio() throws {
    #expect(try ApplePlatformMCPCommand.parse([]) == .serve(transport: .stdio))
  }

  @Test("requires an explicit transport for the serve command")
  func rejectsBareServe() {
    #expect(
      throws: MailError.invalidInput(
        "Only --transport stdio is currently supported. Streamable HTTP will be added separately."
      )
    ) {
      try ApplePlatformMCPCommand.parse(["serve"])
    }
  }

  @Test("accepts an explicit stdio transport")
  func parsesExplicitStdio() throws {
    #expect(
      try ApplePlatformMCPCommand.parse(["serve", "--transport", "stdio"])
        == .serve(transport: .stdio))
  }

  @Test("preserves the explicit Automation setup command")
  func parsesAutomationSetup() throws {
    #expect(
      try ApplePlatformMCPCommand.parse(["doctor", "--request-automation"])
        == .doctor(requestAutomation: true))
  }

  @Test("rejects transports that are not implemented")
  func rejectsUnsupportedTransport() {
    #expect(throws: MailError.self) {
      try ApplePlatformMCPCommand.parse(["serve", "--transport", "streamable-http"])
    }
  }
}

@Suite("MCP contract")
struct MCPContractTests {
  @Test("constructs a configured server independently of its transport")
  func constructsServerBeforeSelectingTransport() async throws {
    let repository = FakeMailRepository(accounts: [])
    let service = MailToolService(repository: repository)
    let configuredServer = await ApplePlatformMCPServer(service: service).makeServer()
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let serverTask = Task {
      try await configuredServer.start(transport: serverTransport)
      await configuredServer.waitUntilCompleted()
    }
    let client = Client(name: "factory-contract-test", version: "1.0.0")

    let initialized = try await client.connect(transport: clientTransport)
    #expect(initialized.serverInfo.name == "apple-platform-mcp")
    #expect(
      Set(try await client.listTools().tools.map(\.name))
        == Set(MCPToolCatalog.tools.map(\.name)))

    await client.disconnect()
    await serverTransport.disconnect()
    _ = try await serverTask.value
  }

  @Test("serves discovery and diagnostics over the in-memory transport")
  func inMemoryLifecycle() async throws {
    let repository = FakeMailRepository(accounts: [])
    let service = MailToolService(repository: repository)
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let serverTask = Task {
      try await ApplePlatformMCPServer(service: service).run(transport: serverTransport)
    }
    let client = Client(name: "contract-test", version: "1.0.0")

    let initialized = try await client.connect(transport: clientTransport)
    #expect(initialized.serverInfo.name == "apple-platform-mcp")

    let listed = try await client.listTools()
    let names = Set(listed.tools.map(\.name))
    #expect(
      names == [
        "mail_server_info",
        "mail_list_accounts",
        "mail_list_mailboxes",
        "mail_search_messages",
        "mail_get_message",
      ])

    let searchTool = try #require(listed.tools.first(where: { $0.name == "mail_search_messages" }))
    let searchSchema = try #require(searchTool.inputSchema.objectValue)
    #expect(searchSchema["additionalProperties"]?.boolValue == false)
    #expect(
      searchSchema["properties"]?.objectValue?["limit"]?.objectValue?["type"]?.stringValue
        == "integer")
    #expect(
      searchSchema["properties"]?.objectValue?["cursor"]?.objectValue?["type"]?.stringValue
        == "string")

    let info = try await client.callTool(name: "mail_server_info")
    #expect(info.isError == false)
    #expect(!info.content.isEmpty)

    await client.disconnect()
    await serverTransport.disconnect()
    _ = try await serverTask.value
  }
}

@Suite("Application service")
struct MailToolServiceTests {
  @Test("filters accounts through the policy allowlist")
  func filtersAccountsThroughPolicyAllowlist() async throws {
    let allowed = ReferenceCodec.account(rawID: "allowed")
    let other = ReferenceCodec.account(rawID: "other")
    let repository = FakeMailRepository(accounts: [
      MailAccountModel(id: allowed, displayName: "Allowed", emailAddresses: [], enabled: true),
      MailAccountModel(id: other, displayName: "Other", emailAddresses: [], enabled: true),
    ])
    let service = MailToolService(
      repository: repository, policy: MailPolicy(allowedAccountIDs: [allowed]))

    let accounts = try await service.listAccounts(includeDisabled: false)

    #expect(accounts.map(\.displayName) == ["Allowed"])
  }
}

private actor FakeMailRepository: MailRepository {
  let accounts: [MailAccountModel]

  init(accounts: [MailAccountModel]) {
    self.accounts = accounts
  }

  func listAccounts(includeDisabled: Bool) async throws -> [MailAccountModel] {
    accounts.filter { includeDisabled || $0.enabled }
  }

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
}
