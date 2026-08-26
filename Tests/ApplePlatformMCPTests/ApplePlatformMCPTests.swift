import Foundation
import MCP
import Testing

#if !XCODE_COMBINED_TEST_TARGET
  import ApplePlatformMCPKit
#endif

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

@Suite("Mail metadata reads")
struct MailMetadataReadTests {
  @Test("metadata-only reads do not require source, body parsing, or attachment content")
  func metadataOnlyReadPlan() {
    let plan = MailMessageReadPlan(includeBody: false, includeAttachmentMetadata: false)

    #expect(plan.loadsMessageSource == false)
    #expect(plan.parsesBody == false)
    #expect(plan.loadsAttachmentContent == false)
    #expect(plan.readsHeaders == true)
  }

  @Test("body reads opt into source and body parsing but not attachment content")
  func bodyReadPlan() {
    let plan = MailMessageReadPlan(includeBody: true, includeAttachmentMetadata: false)

    #expect(plan.loadsMessageSource)
    #expect(plan.parsesBody)
    #expect(plan.loadsAttachmentContent == false)
  }
}

@Suite("Bounded newest-first traversal")
struct BoundedNewestFirstTraversalTests {
  private struct Element: Sendable {
    let id: String
    let receivedAt: Date?
    let matches: Bool
  }

  @Test("merges sources newest-first and stops after the requested page plus lookahead")
  func boundedOrderingAndWork() {
    let sourceA = [
      Element(id: "a3", receivedAt: Date(timeIntervalSince1970: 30), matches: true),
      Element(id: "a1", receivedAt: Date(timeIntervalSince1970: 10), matches: true),
      Element(id: "a0", receivedAt: Date(timeIntervalSince1970: 0), matches: true),
    ]
    let sourceB = [
      Element(id: "b2", receivedAt: Date(timeIntervalSince1970: 20), matches: true),
      Element(id: "b1", receivedAt: Date(timeIntervalSince1970: 15), matches: true),
      Element(id: "b0", receivedAt: Date(timeIntervalSince1970: 5), matches: true),
    ]

    let result = BoundedNewestFirstTraversal.search(
      sources: [sourceA, sourceB],
      offset: 0,
      limit: 3,
      date: { $0.receivedAt },
      matches: { $0.matches },
      elementAt: { source, index in source[index] },
      count: { $0.count }
    )

    #expect(result.elements.map(\.id) == ["a3", "b2", "b1"])
    #expect(result.hasMore)
    #expect(result.inspected < sourceA.count + sourceB.count)
  }

  @Test("offset pages preserve the same ordering")
  func offsetPagination() {
    let source = (1...5).reversed().map {
      Element(
        id: "m\($0)", receivedAt: Date(timeIntervalSince1970: TimeInterval($0)), matches: true)
    }

    let result = BoundedNewestFirstTraversal.search(
      sources: [Array(source)],
      offset: 2,
      limit: 2,
      date: { $0.receivedAt },
      matches: { $0.matches },
      elementAt: { source, index in source[index] },
      count: { $0.count }
    )

    #expect(result.elements.map(\.id) == ["m3", "m2"])
    #expect(result.hasMore)
  }
}

@Suite("Canonical Inbox resolution")
struct CanonicalInboxResolutionTests {
  @Test("selects Mail.app-provided canonical candidates without localized-name heuristics")
  func selectsByAccountReference() {
    let account = ReferenceCodec.account(rawID: "account-1")
    let candidate = CanonicalInboxCandidate(
      accountID: account,
      mailboxID: ReferenceCodec.mailbox(accountRawID: "account-1", path: ["Posteingang"]),
      path: ["Posteingang"]
    )
    let unrelated = CanonicalInboxCandidate(
      accountID: ReferenceCodec.account(rawID: "account-2"),
      mailboxID: ReferenceCodec.mailbox(accountRawID: "account-2", path: ["INBOX"]),
      path: ["INBOX"]
    )

    let resolved = CanonicalInboxResolver.resolve(
      accountID: account,
      candidates: [unrelated, candidate]
    )

    #expect(resolved == candidate)
  }

  @Test("does not invent an Inbox when Mail.app exposes no canonical candidate")
  func doesNotGuess() {
    let account = ReferenceCodec.account(rawID: "account-1")
    #expect(CanonicalInboxResolver.resolve(accountID: account, candidates: []) == nil)
  }

  @Test("prefers the account-specific child over Mail.app's aggregate Inbox container")
  func prefersSpecificChildOverAggregateContainer() {
    let account = ReferenceCodec.account(rawID: "account-1")
    let aggregate = CanonicalInboxCandidate(
      accountID: account,
      mailboxID: ReferenceCodec.mailbox(
        accountRawID: "account-1", path: ["All Inboxes"]),
      path: ["All Inboxes"]
    )
    let specific = CanonicalInboxCandidate(
      accountID: account,
      mailboxID: ReferenceCodec.mailbox(
        accountRawID: "account-1", path: ["All Inboxes", "Account Inbox"]),
      path: ["All Inboxes", "Account Inbox"]
    )

    #expect(
      CanonicalInboxResolver.resolve(accountID: account, candidates: [aggregate, specific])
        == specific
    )
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

@Suite("Search scopes")
struct MailSearchScopeTests {
  @Test("unscoped search defaults to the canonical Inbox scope")
  func defaultsToInbox() {
    #expect(MailSearchQuery().scope == .inbox)
  }

  @Test("scope changes invalidate an existing cursor")
  func cursorBindsScope() {
    let inboxQuery = MailSearchQuery(scope: .inbox, limit: 10)
    let cursor = SearchCursorCodec.encode(query: inboxQuery, offset: 10)

    #expect(throws: MailError.self) {
      try SearchCursorCodec.decode(
        cursor,
        query: MailSearchQuery(scope: .all, limit: 10)
      )
    }
  }
}

@Suite("Sending policy")
struct MailSendingPolicyTests {
  private static let account = MailAccountModel(
    id: ReferenceCodec.account(rawID: "send-account"),
    displayName: "Send Fixture",
    emailAddresses: ["from@example.invalid"],
    enabled: true
  )

  @Test("allowed sending delegates the validated request to the repository")
  func allowsSending() async throws {
    let repository = FakeMailRepository(accounts: [Self.account])
    let service = MailToolService(
      repository: repository,
      policy: MailPolicy(sendMode: .allowed)
    )
    let request = MailSendRequest(
      accountID: Self.account.id,
      fromIdentity: "from@example.invalid",
      to: [MailAddress(address: "recipient@example.invalid")],
      subject: "Hello",
      body: "Message body"
    )

    let result = try await service.sendMessage(request)

    #expect(result.accepted)
    #expect(await repository.recordedSendRequest() == request)
  }

  @Test("rejects a disabled account before delegation")
  func rejectsDisabledAccount() async {
    let account = MailAccountModel(
      id: Self.account.id,
      displayName: Self.account.displayName,
      emailAddresses: Self.account.emailAddresses,
      enabled: false
    )
    let service = MailToolService(
      repository: FakeMailRepository(accounts: [account]),
      policy: MailPolicy(sendMode: .allowed)
    )
    await #expect(throws: MailError.self) {
      try await service.sendMessage(
        MailSendRequest(
          accountID: account.id,
          fromIdentity: "from@example.invalid",
          to: [MailAddress(address: "recipient@example.invalid")],
          subject: "Hello",
          body: "Body"
        )
      )
    }
  }

  @Test("rejects From identities not configured on the account")
  func rejectsFromSpoofing() async {
    let service = MailToolService(
      repository: FakeMailRepository(accounts: [Self.account]),
      policy: MailPolicy(sendMode: .allowed)
    )
    await #expect(throws: MailError.self) {
      try await service.sendMessage(
        MailSendRequest(
          accountID: Self.account.id,
          fromIdentity: "spoof@example.invalid",
          to: [MailAddress(address: "recipient@example.invalid")],
          subject: "Hello",
          body: "Body"
        )
      )
    }
  }

  @Test("rejects empty and malformed recipient lists")
  func rejectsRecipientLists() async {
    let service = MailToolService(
      repository: FakeMailRepository(accounts: [Self.account]),
      policy: MailPolicy(sendMode: .allowed)
    )
    for recipients in [
      [MailAddress](),
      [MailAddress(address: "not-an-email")],
    ] {
      await #expect(throws: MailError.self) {
        try await service.sendMessage(
          MailSendRequest(
            accountID: Self.account.id,
            fromIdentity: "from@example.invalid",
            to: recipients,
            subject: "Hello",
            body: "Body"
          )
        )
      }
    }
  }

  @Test("enforces subject and body send limits")
  func enforcesSendLimits() async {
    let service = MailToolService(
      repository: FakeMailRepository(accounts: [Self.account]),
      policy: MailPolicy(sendMode: .allowed, maxSendBodyBytes: 3, maxSubjectBytes: 3)
    )
    await #expect(throws: MailError.self) {
      try await service.sendMessage(
        MailSendRequest(
          accountID: Self.account.id,
          fromIdentity: "from@example.invalid",
          to: [MailAddress(address: "recipient@example.invalid")],
          subject: "Long",
          body: "ok"
        )
      )
    }
    await #expect(throws: MailError.self) {
      try await service.sendMessage(
        MailSendRequest(
          accountID: Self.account.id,
          fromIdentity: "from@example.invalid",
          to: [MailAddress(address: "recipient@example.invalid")],
          subject: "ok",
          body: "Long"
        )
      )
    }
  }
}

@Suite("Mutation policy")
struct MailMutationPolicyTests {
  private static let account = MailAccountModel(
    id: ReferenceCodec.account(rawID: "mutation-account"),
    displayName: "Mutation Fixture",
    emailAddresses: ["from@example.invalid"],
    enabled: true
  )
  private static let inbox = Mailbox(
    id: ReferenceCodec.mailbox(accountRawID: "mutation-account", path: ["Inbox"]),
    accountID: account.id,
    name: "Inbox",
    path: ["Inbox"],
    role: .inbox,
    unreadCount: 1,
    totalCount: 1
  )
  private static let archive = Mailbox(
    id: ReferenceCodec.mailbox(accountRawID: "mutation-account", path: ["Archive"]),
    accountID: account.id,
    name: "Archive",
    path: ["Archive"],
    role: .archive,
    unreadCount: 0,
    totalCount: 0
  )
  private static let messageID = ReferenceCodec.message(
    accountRawID: "mutation-account",
    mailboxPath: ["Inbox"],
    messageRawID: "message-1"
  )

  @Test("denies mutations by default before repository delegation")
  func deniesMutationsByDefault() async {
    let repository = FakeMailRepository(accounts: [Self.account])
    let service = MailToolService(repository: repository)

    await #expect(throws: MailError.self) {
      try await service.trashMessage(Self.messageID)
    }

    #expect(await repository.recordedTrashMessageID() == nil)
  }

  @Test("keeps confirmation-required mutations fail-closed")
  func requiresExplicitConfirmation() {
    #expect(throws: MailError.self) {
      try MailPolicy(mutationMode: .confirmationRequired).validateMutation()
    }
  }

  @Test("allows a draft when mutation mode is explicitly enabled")
  func allowsDraft() async throws {
    let repository = FakeMailRepository(accounts: [Self.account])
    let service = MailToolService(
      repository: repository,
      policy: MailPolicy(mutationMode: .allowed)
    )
    let request = MailDraftRequest(
      accountID: Self.account.id,
      fromIdentity: "from@example.invalid",
      subject: "Draft subject",
      body: "Draft body"
    )

    let result = try await service.createDraft(request)

    #expect(result.accepted)
    #expect(await repository.recordedDraftRequest() == request)
  }

  @Test("archives through the unique allowed archive mailbox")
  func archivesMessage() async throws {
    let repository = FakeMailRepository(
      accounts: [Self.account],
      mailboxes: [Self.inbox, Self.archive]
    )
    let service = MailToolService(
      repository: repository,
      policy: MailPolicy(mutationMode: .allowed)
    )

    let result = try await service.archiveMessage(Self.messageID)

    #expect(result.operation == .archive)
    #expect(await repository.recordedMoveMessageID() == Self.messageID)
    #expect(await repository.recordedMoveMailboxID() == Self.archive.id)
  }

  @Test("rejects an update without an explicit status")
  func rejectsEmptyUpdate() async {
    let service = MailToolService(
      repository: FakeMailRepository(accounts: [Self.account]),
      policy: MailPolicy(mutationMode: .allowed)
    )

    await #expect(throws: MailError.self) {
      try await service.updateMessage(MailMessageUpdateRequest(id: Self.messageID))
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

  @Test("decodes separately controlled send and mutation modes")
  func decodesSendMode() throws {
    let configuration = try JSONDecoder().decode(
      MailServerConfiguration.self,
      from: Data(#"{"send_mode":"allowed","mutation_mode":"allowed"}"#.utf8)
    )

    #expect(configuration.policy.sendMode == .allowed)
    #expect(configuration.policy.mutationMode == .allowed)
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
  @Test("exposes read tools and policy-controlled write tools")
  func readAndMutationTools() {
    let names = Set(MCPToolCatalog.tools.map(\.name))
    #expect(
      names == [
        "mail_server_info",
        "mail_list_accounts",
        "mail_list_mailboxes",
        "mail_search_messages",
        "mail_get_message",
        "reminder_list_lists",
        "reminder_list_reminders",
        "reminder_get_reminder",
        "reminder_create_reminder",
        "reminder_update_reminder",
        "reminder_complete_reminder",
        "reminder_delete_reminder",
        "reminder_create_list",
        "reminder_update_list",
        "reminder_delete_list",
        "mail_send_message",
        "mail_create_draft",
        "mail_move_message",
        "mail_archive_message",
        "mail_trash_message",
        "mail_update_message",
      ])
    #expect(
      MCPToolCatalog.tools.first(where: { $0.name == "mail_send_message" })?.annotations
        .readOnlyHint
        == false)
    #expect(
      MCPToolCatalog.tools.first(where: { $0.name == "mail_trash_message" })?.annotations
        .destructiveHint
        == true)
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
        "Usage: apple-platform-mcp serve --transport stdio|streamable-http [--host 127.0.0.1 --port 8765] [--config /absolute/path]"
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

  @Test("accepts an explicit absolute configuration path for stdio")
  func parsesStdioWithConfigurationOverride() throws {
    let configurationURL = URL(
      fileURLWithPath: "/private/tmp/apple-platform-mcp-reminders-smoke.json"
    )

    #expect(
      try ApplePlatformMCPCommand.parse([
        "serve",
        "--transport", "stdio",
        "--config", configurationURL.path,
      ])
        == .serve(transport: .stdio, configurationURL: configurationURL))
  }

  @Test("rejects relative configuration paths")
  func rejectsRelativeConfigurationOverride() {
    #expect(throws: MailError.self) {
      try ApplePlatformMCPCommand.parse([
        "serve",
        "--transport", "stdio",
        "--config", "reminders-smoke.json",
      ])
    }
  }

  @Test("preserves the explicit Automation setup command")
  func parsesAutomationSetup() throws {
    #expect(
      try ApplePlatformMCPCommand.parse(["doctor", "--request-automation"])
        == .doctor(requestAutomation: true))
  }

  @Test("parses the explicit Reminders permission setup command")
  func parsesRemindersSetup() throws {
    #expect(
      try ApplePlatformMCPCommand.parse(["doctor", "--request-reminders"])
        == .doctorReminders)
  }

  @Test("rejects transports that are not implemented")
  func rejectsUnsupportedTransport() {
    #expect(throws: MailError.self) {
      try ApplePlatformMCPCommand.parse(["serve", "--transport", "sse"])
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
        "reminder_list_lists",
        "reminder_list_reminders",
        "reminder_get_reminder",
        "reminder_create_reminder",
        "reminder_update_reminder",
        "reminder_complete_reminder",
        "reminder_delete_reminder",
        "reminder_create_list",
        "reminder_update_list",
        "reminder_delete_list",
        "mail_send_message",
        "mail_create_draft",
        "mail_move_message",
        "mail_archive_message",
        "mail_trash_message",
        "mail_update_message",
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
    #expect(
      searchSchema["properties"]?.objectValue?["scope"]?.objectValue?["type"]?.stringValue
        == "string")

    let info = try await client.callTool(name: "mail_server_info")
    #expect(info.isError == false)
    #expect(!info.content.isEmpty)

    await client.disconnect()
    await serverTransport.disconnect()
    _ = try await serverTask.value
  }

  @Test("routes the send tool through the independent send policy")
  func sendsThroughMCP() async throws {
    let account = MailAccountModel(
      id: ReferenceCodec.account(rawID: "mcp-send-account"),
      displayName: "MCP Send Fixture",
      emailAddresses: ["from@example.invalid"],
      enabled: true
    )
    let repository = FakeMailRepository(accounts: [account])
    let service = MailToolService(
      repository: repository,
      policy: MailPolicy(sendMode: .allowed)
    )
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let serverTask = Task {
      try await ApplePlatformMCPServer(service: service).run(transport: serverTransport)
    }
    let client = Client(name: "send-contract-test", version: "1.0.0")

    _ = try await client.connect(transport: clientTransport)
    let result = try await client.callTool(
      name: "mail_send_message",
      arguments: [
        "account_id": .string(account.id.opaqueValue),
        "from_identity": .string("from@example.invalid"),
        "to": .array([.object(["address": .string("recipient@example.invalid")])]),
        "subject": .string("Hello"),
        "body": .string("Message body"),
      ]
    )

    #expect(result.isError == false)
    #expect(await repository.recordedSendRequest()?.subject == "Hello")

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
  @Test("preserves explicit search scope when applying policy bounds")
  func preservesSearchScope() async throws {
    let repository = FakeMailRepository(accounts: [])
    let service = MailToolService(repository: repository)

    _ = try await service.searchMessages(MailSearchQuery(scope: .all, limit: 10))

    #expect(await repository.recordedSearchQuery()?.scope == .all)
  }

  @Test("rejects body-backed text search in metadata-only V1 search")
  func rejectsTextSearch() async {
    let service = MailToolService(repository: FakeMailRepository(accounts: []))

    await #expect(throws: MailError.self) {
      try await service.searchMessages(MailSearchQuery(text: "body phrase", limit: 10))
    }
  }
}

private actor FakeMailRepository: MailRepository {
  let accounts: [MailAccountModel]
  let mailboxes: [Mailbox]
  private var lastQuery: MailSearchQuery?
  private var lastSendRequest: MailSendRequest?
  private var lastDraftRequest: MailDraftRequest?
  private var lastMoveMessageID: MessageReference?
  private var lastMoveMailboxID: MailboxReference?
  private var lastTrashMessageID: MessageReference?
  private var lastUpdateRequest: MailMessageUpdateRequest?

  init(accounts: [MailAccountModel], mailboxes: [Mailbox] = []) {
    self.accounts = accounts
    self.mailboxes = mailboxes
  }

  func recordedSearchQuery() -> MailSearchQuery? {
    lastQuery
  }

  func recordedSendRequest() -> MailSendRequest? {
    lastSendRequest
  }

  func recordedDraftRequest() -> MailDraftRequest? {
    lastDraftRequest
  }

  func recordedMoveMessageID() -> MessageReference? {
    lastMoveMessageID
  }

  func recordedMoveMailboxID() -> MailboxReference? {
    lastMoveMailboxID
  }

  func recordedTrashMessageID() -> MessageReference? {
    lastTrashMessageID
  }

  func recordedUpdateRequest() -> MailMessageUpdateRequest? {
    lastUpdateRequest
  }

  func listAccounts(includeDisabled: Bool) async throws -> [MailAccountModel] {
    accounts.filter { includeDisabled || $0.enabled }
  }

  func listMailboxes(accountID: AccountReference, includeCounts: Bool) async throws -> [Mailbox] {
    mailboxes.filter { $0.accountID == accountID }
  }

  func searchMessages(_ query: MailSearchQuery) async throws -> MailSearchPage {
    lastQuery = query
    return MailSearchPage(messages: [])
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
    lastSendRequest = request
    return MailSendResult(
      accepted: true,
      accountID: request.accountID,
      fromIdentity: request.fromIdentity
    )
  }

  func createDraft(_ request: MailDraftRequest) async throws -> MailDraftResult {
    lastDraftRequest = request
    return MailDraftResult(
      accepted: true,
      accountID: request.accountID,
      fromIdentity: request.fromIdentity,
      subject: request.subject
    )
  }

  func moveMessage(
    id: MessageReference,
    to mailboxID: MailboxReference
  ) async throws -> MailMessageMutationResult {
    lastMoveMessageID = id
    lastMoveMailboxID = mailboxID
    return MailMessageMutationResult(
      accepted: true,
      operation: .move,
      messageID: id,
      targetMailboxID: mailboxID
    )
  }

  func trashMessage(_ id: MessageReference) async throws -> MailMessageMutationResult {
    lastTrashMessageID = id
    return MailMessageMutationResult(accepted: true, operation: .trash, messageID: id)
  }

  func updateMessage(
    _ request: MailMessageUpdateRequest
  ) async throws -> MailMessageMutationResult {
    lastUpdateRequest = request
    return MailMessageMutationResult(accepted: true, operation: .update, messageID: request.id)
  }
}

#if canImport(MailScriptingBridge)
  @Suite("Local Mail.app read integration")
  struct LocalMailAppReadIntegrationTests {
    @Test("resolves a message reference from Mail.app's canonical Inbox")
    func resolvesCanonicalInboxMessage() async throws {
      let repository: ScriptingBridgeMailRepository
      do {
        repository = try ScriptingBridgeMailRepository()
      } catch MailError.mailNotRunning {
        return
      } catch MailError.permissionDenied {
        return
      }

      do {
        let page = try await repository.searchMessages(MailSearchQuery(limit: 1))
        guard let summary = page.messages.first else { return }
        let record = try await repository.getMessage(
          id: summary.id,
          includeBody: false,
          bodyFormat: .plainText,
          includeAttachmentMetadata: false,
          maxBodyBytes: 1_024
        )
        #expect(record.summary.id == summary.id)
        #expect(record.body == nil)
      } catch MailError.mailNotRunning {
        return
      } catch MailError.permissionDenied {
        return
      }
    }
  }
#endif
