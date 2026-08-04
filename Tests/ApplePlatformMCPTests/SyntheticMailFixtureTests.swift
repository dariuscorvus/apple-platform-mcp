import Foundation
import MCP
import Testing

#if !XCODE_COMBINED_TEST_TARGET
  import ApplePlatformMCPKit
#endif

@Suite("Synthetic Mail fixture")
struct SyntheticMailFixtureTests {
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
    #expect(secondPage.messages.first?.subject == "Invoice 3")
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
      mailboxes: [mailbox],
      records: records ?? Self.records
    )
  }
}

private actor SyntheticMailRepository: MailRepository {
  let accounts: [MailAccountModel]
  let mailboxes: [Mailbox]
  let records: [MailMessageRecord]

  init(
    accounts: [MailAccountModel],
    mailboxes: [Mailbox],
    records: [MailMessageRecord]
  ) {
    self.accounts = accounts
    self.mailboxes = mailboxes
    self.records = records
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
    let matches = records.map(\.summary).filter { summary in
      if let accountIDs = query.accountIDs, !accountIDs.contains(summary.accountID) {
        return false
      }
      if let mailboxIDs = query.mailboxIDs, !mailboxIDs.contains(summary.mailboxID) {
        return false
      }
      if let subject = query.subject,
        !(summary.subject?.localizedCaseInsensitiveContains(subject) ?? false)
      {
        return false
      }
      if let from = query.from,
        !(summary.sender?.address.localizedCaseInsensitiveContains(from) ?? false)
      {
        return false
      }
      if query.unreadOnly && summary.isRead { return false }
      if query.flaggedOnly && !summary.isFlagged { return false }
      return query.matchesReceivedDate(summary.receivedAt)
    }

    let boundedLimit = max(1, query.limit)
    let page = Array(matches.dropFirst(offset).prefix(boundedLimit))
    let end = offset + page.count
    let nextCursor =
      end < matches.count
      ? SearchCursorCodec.encode(query: query, offset: end)
      : nil
    return MailSearchPage(messages: page, nextCursor: nextCursor)
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
}
