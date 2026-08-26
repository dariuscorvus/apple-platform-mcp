import Foundation
import MCP
import Testing

#if !XCODE_COMBINED_TEST_TARGET
  import ApplePlatformMCPKit
#endif

@Suite("Synthetic Mail fixture")
struct SyntheticMailFixtureTests {
  @Test("default Inbox search is newest-first and does bounded work")
  func defaultInboxSearchIsNewestFirstAndBounded() async throws {
    let repository = SyntheticMailFixture.repository()
    let service = MailToolService(repository: repository)

    let page = try await service.searchMessages(MailSearchQuery(limit: 2))

    #expect(page.messages.compactMap(\.subject) == ["Invoice 3", "Invoice 2"])
    #expect(await repository.lastInspectedCount() < 4)
  }

  @Test("unread and sender filters stay within the canonical Inbox")
  func filtersInboxSummaries() async throws {
    let repository = SyntheticMailFixture.repository()
    let service = MailToolService(repository: repository)

    let page = try await service.searchMessages(
      MailSearchQuery(from: "billing@example.invalid", unreadOnly: true, limit: 10)
    )

    #expect(page.messages.compactMap(\.subject) == ["Invoice 2", "Invoice 1"])
  }

  @Test("explicit all scope includes the non-Inbox fixture mailbox")
  func explicitAllScope() async throws {
    let service = MailToolService(repository: SyntheticMailFixture.repository())

    let page = try await service.searchMessages(MailSearchQuery(scope: .all, limit: 10))

    #expect(page.messages.first?.subject == "Invoice archive")
    #expect(page.messages.count == 4)
  }

  @Test("serves opaque paginated results over MCP")
  func servesSearchPageOverMCP() async throws {
    let service = MailToolService(repository: SyntheticMailFixture.repository())
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let serverTask = Task {
      try await ApplePlatformMCPServer(service: service).run(transport: serverTransport)
    }
    let client = Client(name: "synthetic-fixture-test", version: "1.0.0")

    _ = try await client.connect(transport: clientTransport)
    let firstResult = try await client.callTool(
      name: "mail_search_messages",
      arguments: [
        "subject": .string("invoice"),
        "limit": .int(2),
      ]
    )
    #expect(firstResult.isError == false)

    let firstEnvelope = try Self.envelope(from: firstResult.content)
    let firstData = try #require(firstEnvelope["data"]?.objectValue)
    #expect(firstData["messages"]?.arrayValue?.count == 2)
    let messageID = try #require(
      firstData["messages"]?.arrayValue?.first?.objectValue?["id"]?.stringValue
    )
    #expect(messageID.hasPrefix("r1_"))
    let cursor = try #require(firstData["nextCursor"]?.stringValue)
    #expect(cursor.hasPrefix("c1_"))

    let secondResult = try await client.callTool(
      name: "mail_search_messages",
      arguments: [
        "subject": .string("invoice"),
        "limit": .int(2),
        "cursor": .string(cursor),
      ]
    )
    #expect(secondResult.isError == false)

    let secondEnvelope = try Self.envelope(from: secondResult.content)
    let secondData = try #require(secondEnvelope["data"]?.objectValue)
    #expect(secondData["messages"]?.arrayValue?.count == 1)
    #expect(secondData["nextCursor"] == nil)

    await client.disconnect()
    await serverTransport.disconnect()
    _ = try await serverTask.value
  }

  @Test("returns bounded search pages with an opaque continuation")
  func paginatesSearchResults() async throws {
    let service = MailToolService(repository: SyntheticMailFixture.repository())
    let firstQuery = MailSearchQuery(subject: "invoice", limit: 2)

    let firstPage = try await service.searchMessages(firstQuery)

    #expect(firstPage.messages.count == 2)
    #expect(firstPage.nextCursor?.hasPrefix("c1_") == true)

    let secondPage = try await service.searchMessages(
      MailSearchQuery(subject: "invoice", limit: 2, cursor: firstPage.nextCursor)
    )

    #expect(secondPage.messages.count == 1)
    #expect(secondPage.nextCursor == nil)
    #expect(secondPage.messages.first?.subject == "Invoice 1")
  }

  @Test("uses strict received-date bounds and excludes undated messages")
  func filtersByReceivedDate() async throws {
    let undated = MailMessageRecord(
      summary: MailMessageSummary(
        id: ReferenceCodec.message(
          accountRawID: "fixture-account",
          mailboxPath: ["Inbox"],
          messageRawID: "undated"
        ),
        accountID: SyntheticMailFixture.account.id,
        mailboxID: SyntheticMailFixture.mailbox.id,
        subject: "Undated invoice",
        sender: MailAddress(address: "billing@example.invalid"),
        recipients: [MailAddress(address: "fixture@example.invalid")],
        receivedAt: nil,
        sentAt: nil,
        isRead: false,
        isFlagged: false,
        hasAttachments: false,
        size: nil
      ),
      messageIDHeader: nil,
      inReplyTo: nil,
      references: [],
      body: nil,
      attachments: []
    )
    let service = MailToolService(
      repository: SyntheticMailFixture.repository(
        records: SyntheticMailFixture.records + [undated]
      )
    )

    let page = try await service.searchMessages(
      MailSearchQuery(
        after: Date(timeIntervalSince1970: 2),
        before: Date(timeIntervalSince1970: 4),
        limit: 10
      )
    )

    #expect(page.messages.compactMap(\.subject) == ["Invoice 3"])
    #expect(page.nextCursor == nil)
  }

  @Test("returns bounded body and opaque attachment metadata")
  func readsMessageDetail() async throws {
    let service = MailToolService(repository: SyntheticMailFixture.repository())
    let record = try await service.getMessage(
      id: SyntheticMailFixture.messageReferences[0],
      includeBody: true,
      bodyFormat: .plainText,
      includeAttachmentMetadata: true,
      maxBodyBytes: 1_024
    )

    #expect(record.body?.plainText?.contains("synthetic fixture") == true)
    #expect(record.attachments.count == 1)
    #expect(record.attachments[0].id.opaqueValue.hasPrefix("r1_"))
    #expect(ReferenceCodec.decode(record.attachments[0].id)?["id"] == "attachment-1")
  }

  @Test("applies account allowlists before repository results leave the service")
  func appliesAccountAllowlist() async throws {
    let allowedAccount = SyntheticMailFixture.account.id
    let service = MailToolService(
      repository: SyntheticMailFixture.repository(),
      policy: MailPolicy(allowedAccountIDs: [allowedAccount])
    )

    let accounts = try await service.listAccounts(includeDisabled: true)
    #expect(accounts.map(\.id) == [allowedAccount])
  }

  @Test("applies mailbox allowlists to message reads")
  func appliesMailboxAllowlist() async {
    let service = MailToolService(
      repository: SyntheticMailFixture.repository(),
      policy: MailPolicy(allowedMailboxIDs: [])
    )

    await #expect(throws: MailError.self) {
      try await service.getMessage(
        id: SyntheticMailFixture.messageReferences[0],
        includeBody: false,
        bodyFormat: .plainText,
        includeAttachmentMetadata: false,
        maxBodyBytes: nil
      )
    }
  }

  private static func envelope(from content: [Tool.Content]) throws -> [String: Value] {
    let text: String
    guard case .text(let value, _, _) = try #require(content.first) else {
      throw MailError.invalidInput("synthetic MCP response did not contain text")
    }
    text = value
    return try JSONDecoder().decode(Value.self, from: Data(text.utf8)).objectValue ?? [:]
  }
}

@Suite("Synthetic workflow benchmark")
struct SyntheticWorkflowBenchmarkTests {
  private struct Row: Codable {
    let workflow: String
    let iterations: Int
    let minimumMilliseconds: Double
    let medianMilliseconds: Double
    let maximumMilliseconds: Double
    let resultCount: Int
  }

  private struct Report: Codable {
    let schemaVersion: Int
    let fixture: String
    let workflows: [Row]
  }

  @Test("measures the bounded V1 agent workflows without emitting mail data")
  func measuresAgentWorkflows() async throws {
    let iterations = 7
    let workflows: [(String, Double, (MailToolService) async throws -> Int)] = [
      (
        "list_accounts", 1_000,
        { service in
          try await service.listAccounts(includeDisabled: false).count
        }
      ),
      (
        "list_mailboxes", 2_000,
        { service in
          try await service.listMailboxes(
            accountID: SyntheticMailFixture.account.id, includeCounts: false
          ).count
        }
      ),
      (
        "newest_10_inbox", 2_000,
        { service in
          try await service.searchMessages(MailSearchQuery(limit: 10)).messages.count
        }
      ),
      (
        "unread_10_inbox", 3_000,
        { service in
          try await service.searchMessages(
            MailSearchQuery(unreadOnly: true, limit: 10)
          ).messages.count
        }
      ),
      (
        "get_metadata_only", 2_000,
        { service in
          let record = try await service.getMessage(
            id: SyntheticMailFixture.messageReferences[0],
            includeBody: false,
            bodyFormat: .plainText,
            includeAttachmentMetadata: false,
            maxBodyBytes: nil
          )
          return record.body == nil ? 1 : 0
        }
      ),
      (
        "get_message_body", 3_000,
        { service in
          let record = try await service.getMessage(
            id: SyntheticMailFixture.messageReferences[0],
            includeBody: true,
            bodyFormat: .plainText,
            includeAttachmentMetadata: false,
            maxBodyBytes: 1_024
          )
          return record.body?.plainText == nil ? 0 : 1
        }
      ),
      (
        "sender_search_inbox", 5_000,
        { service in
          try await service.searchMessages(
            MailSearchQuery(from: "billing@example.invalid", limit: 10)
          ).messages.count
        }
      ),
      (
        "subject_search_inbox", 5_000,
        { service in
          try await service.searchMessages(
            MailSearchQuery(subject: "invoice", limit: 10)
          ).messages.count
        }
      ),
      (
        "broad_archive_search", .infinity,
        { service in
          try await service.searchMessages(
            MailSearchQuery(scope: .all, subject: "invoice", limit: 10)
          ).messages.count
        }
      ),
    ]

    var rows: [Row] = []
    for (workflow, budgetMilliseconds, operation) in workflows {
      var samples: [UInt64] = []
      var resultCount = 0
      for _ in 0..<iterations {
        let service = MailToolService(repository: SyntheticMailFixture.repository())
        let start = DispatchTime.now().uptimeNanoseconds
        resultCount = try await operation(service)
        samples.append(DispatchTime.now().uptimeNanoseconds - start)
      }
      let sorted = samples.sorted()
      let median = sorted[sorted.count / 2]
      let row = Row(
        workflow: workflow,
        iterations: iterations,
        minimumMilliseconds: Double(sorted[0]) / 1_000_000,
        medianMilliseconds: Double(median) / 1_000_000,
        maximumMilliseconds: Double(sorted[sorted.count - 1]) / 1_000_000,
        resultCount: resultCount
      )
      rows.append(row)
      if budgetMilliseconds.isFinite {
        #expect(row.maximumMilliseconds < budgetMilliseconds)
      }
    }

    let report = Report(schemaVersion: 1, fixture: "synthetic", workflows: rows)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(report)
    let line = String(decoding: data, as: UTF8.self)
    FileHandle.standardOutput.write(Data("MAIL_WORKFLOW_BENCHMARK \(line)\n".utf8))
  }
}

private enum SyntheticMailFixture {
  static let account = MailAccountModel(
    id: ReferenceCodec.account(rawID: "fixture-account"),
    displayName: "Synthetic IMAP Fixture",
    emailAddresses: ["fixture@example.invalid"],
    enabled: true
  )

  static let mailbox = Mailbox(
    id: ReferenceCodec.mailbox(accountRawID: "fixture-account", path: ["Inbox"]),
    accountID: account.id,
    name: "Inbox",
    path: ["Inbox"],
    role: .inbox,
    unreadCount: 2,
    totalCount: 3
  )

  static let archiveMailbox = Mailbox(
    id: ReferenceCodec.mailbox(accountRawID: "fixture-account", path: ["Archive"]),
    accountID: account.id,
    name: "Archive",
    path: ["Archive"],
    role: .archive,
    unreadCount: 0,
    totalCount: 1
  )

  static let archiveRecord = MailMessageRecord(
    summary: MailMessageSummary(
      id: ReferenceCodec.message(
        accountRawID: "fixture-account",
        mailboxPath: ["Archive"],
        messageRawID: "archive-message"
      ),
      accountID: account.id,
      mailboxID: archiveMailbox.id,
      subject: "Invoice archive",
      sender: MailAddress(address: "billing@example.invalid"),
      recipients: [MailAddress(address: "fixture@example.invalid")],
      receivedAt: Date(timeIntervalSince1970: 4),
      sentAt: Date(timeIntervalSince1970: 4),
      isRead: true,
      isFlagged: false,
      hasAttachments: false,
      size: 128
    ),
    messageIDHeader: "<archive@example.invalid>",
    inReplyTo: nil,
    references: [],
    body: MailBody(
      plainText: "Archived synthetic fixture message.",
      truncated: false,
      originalByteCount: 35
    ),
    attachments: []
  )

  static let messageReferences = (1...3).map { index in
    ReferenceCodec.message(
      accountRawID: "fixture-account",
      mailboxPath: ["Inbox"],
      messageRawID: "message-\(index)"
    )
  }

  static let records: [MailMessageRecord] = (1...3).map { index in
    let summary = MailMessageSummary(
      id: messageReferences[index - 1],
      accountID: account.id,
      mailboxID: mailbox.id,
      subject: "Invoice \(index)",
      sender: MailAddress(address: "billing@example.invalid", displayName: "Billing Fixture"),
      recipients: [MailAddress(address: "fixture@example.invalid")],
      receivedAt: Date(timeIntervalSince1970: TimeInterval(index)),
      sentAt: Date(timeIntervalSince1970: TimeInterval(index)),
      isRead: index == 3,
      isFlagged: index == 1,
      hasAttachments: index == 1,
      size: 128
    )
    let attachment = MailAttachmentMetadata(
      id: ReferenceCodec.attachment(
        accountRawID: "fixture-account",
        mailboxPath: ["Inbox"],
        messageRawID: "message-\(index)",
        attachmentRawID: "attachment-1"
      ),
      filename: "invoice-\(index).pdf",
      mimeType: "application/pdf",
      byteCount: 64,
      inline: false
    )
    return MailMessageRecord(
      summary: summary,
      messageIDHeader: "<fixture-\(index)@example.invalid>",
      inReplyTo: nil,
      references: [],
      body: MailBody(
        plainText: "Message \(index) from the synthetic fixture.",
        truncated: false,
        originalByteCount: 44
      ),
      attachments: index == 1 ? [attachment] : []
    )
  }

  static func repository(records: [MailMessageRecord]? = nil) -> SyntheticMailRepository {
    SyntheticMailRepository(
      accounts: [account],
      mailboxes: [mailbox, archiveMailbox],
      records: records ?? Self.records + [archiveRecord]
    )
  }
}

private actor SyntheticMailRepository: MailRepository {
  let accounts: [MailAccountModel]
  let mailboxes: [Mailbox]
  let records: [MailMessageRecord]
  private var inspectedCount = 0

  init(
    accounts: [MailAccountModel],
    mailboxes: [Mailbox],
    records: [MailMessageRecord]
  ) {
    self.accounts = accounts
    self.mailboxes = mailboxes
    self.records = records
  }

  func lastInspectedCount() -> Int {
    inspectedCount
  }

  func listAccounts(includeDisabled: Bool) async throws -> [MailAccountModel] {
    accounts.filter { includeDisabled || $0.enabled }
  }

  func listMailboxes(
    accountID: AccountReference,
    includeCounts: Bool
  ) async throws -> [Mailbox] {
    mailboxes.filter { $0.accountID == accountID }
  }

  func searchMessages(_ query: MailSearchQuery) async throws -> MailSearchPage {
    let offset = try SearchCursorCodec.decode(query.cursor, query: query)
    let boundedLimit = max(1, query.limit)
    let scopedRecords = records.filter { record in
      switch query.scope {
      case .inbox:
        return record.summary.mailboxID == SyntheticMailFixture.mailbox.id
      case .mailbox:
        return query.mailboxIDs?.contains(record.summary.mailboxID) == true
      case .all:
        return true
      }
    }
    let orderedRecords = scopedRecords.sorted {
      ($0.summary.receivedAt ?? .distantPast) > ($1.summary.receivedAt ?? .distantPast)
    }

    inspectedCount = 0
    var matchedCount = 0
    var page: [MailMessageSummary] = []
    for record in orderedRecords {
      inspectedCount += 1
      let summary = record.summary
      if let accountIDs = query.accountIDs, !accountIDs.contains(summary.accountID) {
        continue
      }
      if let subject = query.subject,
        !(summary.subject?.localizedCaseInsensitiveContains(subject) ?? false)
      {
        continue
      }
      if let from = query.from,
        !(summary.sender?.address.localizedCaseInsensitiveContains(from) ?? false)
      {
        continue
      }
      if query.unreadOnly && summary.isRead { continue }
      if query.flaggedOnly && !summary.isFlagged { continue }
      if !query.matchesReceivedDate(summary.receivedAt) { continue }

      if matchedCount < offset {
        matchedCount += 1
        continue
      }
      matchedCount += 1
      page.append(summary)
      if page.count > boundedLimit {
        return MailSearchPage(
          messages: Array(page.prefix(boundedLimit)),
          nextCursor: SearchCursorCodec.encode(query: query, offset: offset + boundedLimit)
        )
      }
    }

    return MailSearchPage(messages: page)
  }

  func getMessage(
    id: MessageReference,
    includeBody: Bool,
    bodyFormat: MailBodyFormat,
    includeAttachmentMetadata: Bool,
    maxBodyBytes: Int
  ) async throws -> MailMessageRecord {
    guard let record = records.first(where: { $0.summary.id == id }) else {
      throw MailError.messageNotFound
    }
    return MailMessageRecord(
      summary: record.summary,
      messageIDHeader: record.messageIDHeader,
      inReplyTo: record.inReplyTo,
      references: record.references,
      body: includeBody ? record.body : nil,
      attachments: includeAttachmentMetadata ? record.attachments : []
    )
  }

  func sendMessage(_ request: MailSendRequest) async throws -> MailSendResult {
    MailSendResult(
      accepted: true,
      accountID: request.accountID,
      fromIdentity: request.fromIdentity
    )
  }
}
