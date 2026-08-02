import Foundation

/// The only type that is allowed to touch Mail.app's generated ScriptingBridge
/// objects. The actor serializes every Apple Events call.
public actor ScriptingBridgeMailRepository: MailRepository {
  private let application: MailApplication

  public init() throws {
    guard let application = MailApplication(bundleIdentifier: "com.apple.mail") else {
      throw MailError.mailNotRunning
    }
    self.application = application
  }

  public func listAccounts(includeDisabled: Bool) async throws -> [MailAccountModel] {
    try ensureMailIsReachable()

    return allAccounts().compactMap { account in
      let enabled = account.enabled
      guard includeDisabled || enabled else { return nil }

      let rawID = accountRawID(account)
      return MailAccountModel(
        id: ReferenceCodec.account(rawID: rawID),
        displayName: account.name ?? account.fullName ?? "Unnamed account",
        emailAddresses: account.emailAddresses ?? [],
        enabled: enabled
      )
    }
  }

  public func listMailboxes(
    accountID: AccountReference,
    includeCounts: Bool
  ) async throws -> [Mailbox] {
    try ensureMailIsReachable()

    guard
      let components = ReferenceCodec.decode(accountID),
      let rawAccountID = components["id"],
      let account = allAccounts().first(where: { accountRawID($0) == rawAccountID })
    else {
      throw MailError.accountNotFound
    }

    return collectMailboxes(from: account, accountRawID: rawAccountID, includeCounts: includeCounts)
      .map(\.model)
  }

  public func searchMessages(_ query: MailSearchQuery) async throws -> MailSearchPage {
    try ensureMailIsReachable()

    let offset = try SearchCursorCodec.decode(query.cursor, query: query)

    let selectedAccountIDs = try query.accountIDs?.map { reference -> String in
      guard
        let components = ReferenceCodec.decode(reference),
        let rawID = components["id"]
      else {
        throw MailError.accountNotFound
      }
      return rawID
    }

    let selectedMailboxReferences = query.mailboxIDs ?? []
    let selectedMailboxValues = try selectedMailboxReferences.map { reference in
      guard let components = ReferenceCodec.decode(reference) else {
        throw MailError.invalidInput("mailbox_ids contains an invalid reference")
      }
      return components
    }
    let selectedLimit = max(1, query.limit)
    var results: [MailMessageSummary] = []
    var matchedCount = 0

    for account in allAccounts() where account.enabled {
      let rawAccountID = accountRawID(account)
      if let selectedAccountIDs, !selectedAccountIDs.contains(rawAccountID) {
        continue
      }

      let mailboxes = collectMailboxes(
        from: account, accountRawID: rawAccountID, includeCounts: false)
      for mailbox in mailboxes {
        if !selectedMailboxReferences.isEmpty {
          let matchesMailbox = selectedMailboxValues.contains { components in
            components["account"] == rawAccountID
              && components["path"] == mailbox.path.joined(separator: "\u{1F}")
          }
          if !matchesMailbox { continue }
        }

        for case let message as MailMessage in mailbox.raw.messages() {
          if matches(message, query: query) {
            if matchedCount < offset {
              matchedCount += 1
              continue
            }

            matchedCount += 1
            results.append(
              makeSummary(
                message,
                accountRawID: rawAccountID,
                mailboxPath: mailbox.path,
                mailboxReference: mailbox.model.id,
                accountReference: mailbox.model.accountID
              ).summary)
            if results.count > selectedLimit {
              return MailSearchPage(
                messages: Array(results.dropLast()),
                nextCursor: SearchCursorCodec.encode(
                  query: query,
                  offset: offset + selectedLimit
                )
              )
            }
          }
        }
      }
    }

    return MailSearchPage(messages: results)
  }

  public func getMessage(
    id: MessageReference,
    includeBody: Bool,
    bodyFormat: MailBodyFormat,
    includeAttachmentMetadata: Bool,
    maxBodyBytes: Int
  ) async throws -> MailMessageRecord {
    try ensureMailIsReachable()

    guard
      let components = ReferenceCodec.decode(id),
      let rawAccountID = components["account"],
      let mailboxValue = components["mailbox"],
      let rawMessageID = components["id"],
      let account = allAccounts().first(where: { accountRawID($0) == rawAccountID })
    else {
      throw MailError.messageNotFound
    }

    let mailboxPath = mailboxValue.components(separatedBy: "\u{1F}")
    guard
      let mailbox = collectMailboxes(
        from: account, accountRawID: rawAccountID, includeCounts: false
      )
      .first(where: { $0.path == mailboxPath })
    else {
      throw MailError.mailboxNotFound
    }

    guard
      let message =
        (mailbox.raw.messages().first { raw in
          guard let message = raw as? MailMessage else { return false }
          return messageRawID(message) == rawMessageID
        }) as? MailMessage
    else {
      throw MailError.messageNotFound
    }

    let summary = makeSummary(
      message,
      accountRawID: rawAccountID,
      mailboxPath: mailbox.path,
      mailboxReference: mailbox.model.id,
      accountReference: mailbox.model.accountID
    ).summary

    let source = message.source ?? ""
    let parsed = MailContentSanitizer.parseSource(source)
    let body =
      includeBody
      ? MailContentSanitizer.body(from: source, format: bodyFormat, maxBytes: max(1, maxBodyBytes))
      : nil

    let attachments =
      includeAttachmentMetadata
      ? makeAttachments(
        message,
        accountRawID: rawAccountID,
        mailboxPath: mailbox.path,
        messageRawID: rawMessageID
      )
      : []

    return MailMessageRecord(
      summary: summary,
      messageIDHeader: message.messageId ?? parsed.headers["message-id"],
      inReplyTo: message.replyTo ?? parsed.headers["in-reply-to"],
      references: (parsed.headers["references"] ?? "").split(whereSeparator: { $0.isWhitespace })
        .map(String.init),
      body: body,
      attachments: attachments
    )
  }

  private struct MailboxSnapshot {
    let raw: MailMailbox
    let model: Mailbox
    let path: [String]
  }

  private func collectMailboxes(
    from account: MailAccount,
    accountRawID: String,
    includeCounts: Bool
  ) -> [MailboxSnapshot] {
    var result: [MailboxSnapshot] = []

    func visit(_ mailbox: MailMailbox, path: [String]) {
      let name = mailbox.name ?? "(unnamed)"
      let fullPath = path + [name]
      let mailboxReference = ReferenceCodec.mailbox(accountRawID: accountRawID, path: fullPath)
      let model = Mailbox(
        id: mailboxReference,
        accountID: ReferenceCodec.account(rawID: accountRawID),
        name: name,
        path: fullPath,
        role: role(for: fullPath),
        unreadCount: includeCounts ? mailbox.unreadCount : nil,
        totalCount: includeCounts ? mailbox.messages().count : nil
      )
      result.append(MailboxSnapshot(raw: mailbox, model: model, path: fullPath))

      for case let child as MailMailbox in mailbox.mailboxes() {
        visit(child, path: fullPath)
      }
    }

    for case let mailbox as MailMailbox in account.mailboxes() {
      visit(mailbox, path: [])
    }

    return result
  }

  private func allAccounts() -> [MailAccount] {
    application.accounts().compactMap { $0 as? MailAccount }
  }

  private func accountRawID(_ account: MailAccount) -> String {
    let id = account.id() ?? ""
    return id.isEmpty ? account.name ?? "unknown-account" : id
  }

  private func messageRawID(_ message: MailMessage) -> String {
    if let messageID = message.messageId, !messageID.isEmpty {
      return messageID
    }
    return String(message.id())
  }

  private func makeSummary(
    _ message: MailMessage,
    accountRawID: String,
    mailboxPath: [String],
    mailboxReference: MailboxReference,
    accountReference: AccountReference
  ) -> (summary: MailMessageSummary, rawID: String) {
    let rawID = messageRawID(message)
    let recipientValues = recipientAddresses(for: message)

    return (
      MailMessageSummary(
        id: ReferenceCodec.message(
          accountRawID: accountRawID,
          mailboxPath: mailboxPath,
          messageRawID: rawID
        ),
        accountID: accountReference,
        mailboxID: mailboxReference,
        subject: message.subject,
        sender: MailAddress.parse(message.sender),
        recipients: recipientValues,
        receivedAt: message.dateReceived,
        sentAt: message.dateSent,
        isRead: message.readStatus,
        isFlagged: message.flaggedStatus,
        hasAttachments: (message.mailAttachments()?.count ?? 0) > 0,
        size: message.messageSize
      ),
      rawID: rawID
    )
  }

  private func makeAttachments(
    _ message: MailMessage,
    accountRawID: String,
    mailboxPath: [String],
    messageRawID: String
  ) -> [MailAttachmentMetadata] {
    guard let rawAttachments = message.mailAttachments() else { return [] }
    return rawAttachments.enumerated().compactMap { index, raw in
      guard let attachment = raw as? MailMailAttachment else { return nil }
      return MailAttachmentMetadata(
        id: ReferenceCodec.attachment(
          accountRawID: accountRawID,
          mailboxPath: mailboxPath,
          messageRawID: messageRawID,
          attachmentRawID: attachment.id() ?? "attachment-\(index)"
        ),
        filename: attachment.name,
        mimeType: attachment.mimeType,
        byteCount: attachment.fileSize,
        inline: false
      )
    }
  }

  private func recipientAddresses(for message: MailMessage) -> [MailAddress] {
    guard let rawRecipients = message.toRecipients() else { return [] }
    var recipients: [MailAddress] = []
    for case let recipient as MailRecipient in rawRecipients {
      let address = recipient.address ?? ""
      guard !address.isEmpty else { continue }
      recipients.append(MailAddress(address: address, displayName: recipient.name))
    }
    return recipients
  }

  private func matches(_ message: MailMessage, query: MailSearchQuery) -> Bool {
    if let from = query.from, !contains(message.sender, value: from) {
      return false
    }
    if let subject = query.subject, !contains(message.subject, value: subject) {
      return false
    }
    if let to = query.to {
      let recipients = recipientAddresses(for: message).map(\.address)
      if !recipients.contains(where: { $0.localizedCaseInsensitiveContains(to) }) {
        return false
      }
    }
    if let text = query.text, !contains(message.source, value: text) {
      return false
    }
    if query.unreadOnly && message.readStatus {
      return false
    }
    if query.flaggedOnly && !message.flaggedStatus {
      return false
    }
    if let after = query.after, let received = message.dateReceived, received <= after {
      return false
    }
    if let before = query.before, let received = message.dateReceived, received >= before {
      return false
    }
    return true
  }

  private func contains(_ candidate: String?, value: String) -> Bool {
    candidate?.localizedCaseInsensitiveContains(value) ?? false
  }

  private func role(for path: [String]) -> MailboxRole? {
    guard let last = path.last?.lowercased() else { return nil }
    if last == "inbox" || last == "in" { return .inbox }
    if last.contains("draft") { return .drafts }
    if last.contains("sent") { return .sent }
    if last.contains("archive") { return .archive }
    if last.contains("trash") || last.contains("deleted") { return .trash }
    if last.contains("junk") || last.contains("spam") { return .junk }
    return .custom
  }

  private func ensureMailIsReachable() throws {
    let diagnostics = MailAutomationDiagnostics.inspect()
    guard diagnostics.mailAppInstalled else {
      throw MailError.mailNotRunning
    }
    guard diagnostics.mailAppRunning else {
      throw MailError.mailNotRunning
    }

    switch diagnostics.permission {
    case .allowed:
      return
    case .needsConsent, .denied, .unavailable, .notChecked:
      // Never trigger a consent prompt from an MCP request. The signed
      // host must already have automation access to Mail.app.
      throw MailError.permissionDenied
    }
  }
}
