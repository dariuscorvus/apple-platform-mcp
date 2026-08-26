import Foundation

#if canImport(MailScriptingBridge)
  import MailScriptingBridge
#endif

/// Describes the minimum Mail.app reads needed to build a message record.
///
/// `source` is a body-bearing property. Header reads use Mail.app's separate
/// `all headers` property and never imply HTML parsing or attachment-content
/// access. Keeping this plan explicit makes metadata-only behavior testable.
public struct MailMessageReadPlan: Sendable {
  public let readsHeaders: Bool
  public let loadsMessageSource: Bool
  public let parsesBody: Bool
  public let loadsAttachmentContent: Bool

  public init(includeBody: Bool, includeAttachmentMetadata: Bool) {
    readsHeaders = true
    loadsMessageSource = includeBody
    parsesBody = includeBody
    // Attachment metadata is represented by Mail.app properties. V1 never
    // exports or reads attachment content as part of a message read.
    loadsAttachmentContent = false
    _ = includeAttachmentMetadata
  }
}

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

    let canonicalPath = canonicalInboxSnapshot(
      for: account,
      accountRawID: rawAccountID,
      includeCounts: false
    )?.path.joined(separator: "\u{1F}")
    return collectMailboxes(
      from: account,
      accountRawID: rawAccountID,
      includeCounts: includeCounts,
      canonicalInboxPaths: canonicalPath.map { [$0] } ?? []
    ).map(\.model)
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

    let selectedMailboxValues = try (query.mailboxIDs ?? []).map { reference in
      guard let components = ReferenceCodec.decode(reference) else {
        throw MailError.invalidInput("mailbox_ids contains an invalid reference")
      }
      return components
    }
    let selectedLimit = max(1, query.limit)
    var sources: [SearchSource] = []

    for account in allAccounts() where account.enabled {
      let rawAccountID = accountRawID(account)
      if let selectedAccountIDs, !selectedAccountIDs.contains(rawAccountID) {
        continue
      }

      let mailboxes: [MailboxSnapshot]
      switch query.scope {
      case .inbox:
        mailboxes =
          canonicalInboxSnapshot(
            for: account,
            accountRawID: rawAccountID,
            includeCounts: false
          ).map { [$0] } ?? []
      case .mailbox:
        mailboxes = selectedMailboxValues.compactMap { components in
          guard components["account"] == rawAccountID,
            let pathValue = components["path"]
          else { return nil }
          let path = pathValue.components(separatedBy: "\u{1F}")
          return resolveMailbox(
            from: account,
            accountRawID: rawAccountID,
            path: path,
            includeCounts: false
          )
        }
      case .all:
        mailboxes = collectMailboxes(
          from: account,
          accountRawID: rawAccountID,
          includeCounts: false
        )
      }

      for mailbox in mailboxes {
        sources.append(SearchSource(raw: mailbox.raw.messages(), snapshot: mailbox))
      }
    }

    let traversal = BoundedNewestFirstTraversal.search(
      sources: sources,
      offset: offset,
      limit: selectedLimit,
      date: { $0.message.dateReceived },
      matches: { matches($0.message, query: query) },
      elementAt: { source, index in
        SearchEntry(message: source.raw[index] as! MailMessage, snapshot: source.snapshot)
      },
      count: { $0.raw.count }
    )
    let summaries = traversal.elements.map { entry in
      makeSummary(
        entry.message,
        accountRawID: ReferenceCodec.decode(entry.snapshot.model.accountID)?["id"] ?? "",
        mailboxPath: entry.snapshot.path,
        mailboxReference: entry.snapshot.model.id,
        accountReference: entry.snapshot.model.accountID
      ).summary
    }
    let nextCursor =
      traversal.hasMore
      ? SearchCursorCodec.encode(query: query, offset: offset + selectedLimit)
      : nil
    return MailSearchPage(messages: summaries, nextCursor: nextCursor)
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
    let mailbox =
      collectMailboxes(
        from: account, accountRawID: rawAccountID, includeCounts: false
      ).first(where: { $0.path == mailboxPath })
      ?? canonicalInboxSnapshot(
        for: account, accountRawID: rawAccountID, includeCounts: false
      ).flatMap { $0.path == mailboxPath ? $0 : nil }
    guard let mailbox else {
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

    let readPlan = MailMessageReadPlan(
      includeBody: includeBody,
      includeAttachmentMetadata: includeAttachmentMetadata
    )
    let headerSource = readPlan.readsHeaders ? (message.allHeaders ?? "") : ""
    let parsedHeaders = MailContentSanitizer.parseHeadersOnly(headerSource)
    let source = readPlan.loadsMessageSource ? (message.source ?? "") : nil
    let body =
      readPlan.parsesBody
      ? MailContentSanitizer.body(
        from: source ?? "", format: bodyFormat, maxBytes: max(1, maxBodyBytes))
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
      messageIDHeader: message.messageId ?? parsedHeaders["message-id"],
      inReplyTo: message.replyTo ?? parsedHeaders["in-reply-to"],
      references: (parsedHeaders["references"] ?? "").split(whereSeparator: { $0.isWhitespace })
        .map(String.init),
      body: body,
      attachments: attachments
    )
  }

  public func sendMessage(_ request: MailSendRequest) async throws -> MailSendResult {
    #if canImport(MailScriptingBridge)
      func recipientValues(_ values: [MailAddress]) -> [[String: String]] {
        values.map { address in
          var value = ["address": address.address]
          if let displayName = address.displayName {
            value["name"] = displayName
          }
          return value
        }
      }

      guard
        APSMailScriptingBridgeSendMessage(
          application,
          request.fromIdentity,
          request.subject,
          request.body,
          recipientValues(request.to),
          recipientValues(request.cc),
          recipientValues(request.bcc)
        )
      else {
        throw MailError.unsupportedByAccount
      }
      return MailSendResult(
        accepted: true,
        accountID: request.accountID,
        fromIdentity: request.fromIdentity
      )
    #else
      throw MailError.unsupportedByAccount
    #endif
  }

  private struct MailboxSnapshot {
    let raw: MailMailbox
    let model: Mailbox
    let path: [String]
  }

  private struct SearchSource {
    let raw: SBElementArray
    let snapshot: MailboxSnapshot
  }

  private struct SearchEntry {
    let message: MailMessage
    let snapshot: MailboxSnapshot
  }

  private func canonicalInboxSnapshot(
    for account: MailAccount,
    accountRawID: String,
    includeCounts: Bool
  ) -> MailboxSnapshot? {
    var rawCandidates: [(candidate: CanonicalInboxCandidate, raw: MailMailbox)] = []

    if let canonicalRoot = application.inbox {
      let rootName = canonicalRoot.name ?? "(unnamed)"
      if let owner = canonicalRoot.account,
        self.accountRawID(owner) == accountRawID
      {
        let path = [rootName]
        rawCandidates.append(
          (
            CanonicalInboxCandidate(
              accountID: ReferenceCodec.account(rawID: accountRawID),
              mailboxID: ReferenceCodec.mailbox(accountRawID: accountRawID, path: path),
              path: path
            ),
            canonicalRoot
          )
        )
      }

      for case let child as MailMailbox in canonicalRoot.mailboxes() {
        guard
          let owner = child.account,
          self.accountRawID(owner) == accountRawID
        else { continue }
        let path = mailboxPath(child)
        rawCandidates.append(
          (
            CanonicalInboxCandidate(
              accountID: ReferenceCodec.account(rawID: accountRawID),
              mailboxID: ReferenceCodec.mailbox(accountRawID: accountRawID, path: path),
              path: path
            ),
            child
          )
        )
      }
    }

    let accountReference = ReferenceCodec.account(rawID: accountRawID)
    guard
      let resolved = CanonicalInboxResolver.resolve(
        accountID: accountReference,
        candidates: rawCandidates.map(\.candidate)
      )
    else {
      return nil
    }
    guard let raw = rawCandidates.first(where: { $0.candidate == resolved })?.raw else {
      return nil
    }
    return makeMailboxSnapshot(
      raw,
      accountRawID: accountRawID,
      path: resolved.path,
      role: .inbox,
      includeCounts: includeCounts
    )
  }

  private func resolveMailbox(
    from account: MailAccount,
    accountRawID: String,
    path: [String],
    includeCounts: Bool
  ) -> MailboxSnapshot? {
    guard !path.isEmpty else { return nil }
    var currentMailboxes: SBElementArray? = account.mailboxes()
    var current: MailMailbox?

    for component in path {
      guard
        let mailboxes = currentMailboxes,
        let match = mailboxes.first(where: { mailbox in
          (mailbox as? MailMailbox)?.name == component
        }) as? MailMailbox
      else {
        return nil
      }
      current = match
      currentMailboxes = match.mailboxes()
    }

    guard let current else { return nil }
    return makeMailboxSnapshot(
      current,
      accountRawID: accountRawID,
      path: path,
      role: nil,
      includeCounts: includeCounts
    )
  }

  private func mailboxPath(_ mailbox: MailMailbox) -> [String] {
    var path: [String] = []
    var current: MailMailbox? = mailbox
    var depth = 0
    while let mailbox = current, depth < 32 {
      path.insert(mailbox.name ?? "(unnamed)", at: 0)
      current = mailbox.container
      depth += 1
    }
    return path
  }

  private func makeMailboxSnapshot(
    _ mailbox: MailMailbox,
    accountRawID: String,
    path: [String],
    role: MailboxRole?,
    includeCounts: Bool
  ) -> MailboxSnapshot {
    let name = mailbox.name ?? path.last ?? "(unnamed)"
    let model = Mailbox(
      id: ReferenceCodec.mailbox(accountRawID: accountRawID, path: path),
      accountID: ReferenceCodec.account(rawID: accountRawID),
      name: name,
      path: path,
      role: role ?? self.role(for: path),
      unreadCount: includeCounts ? mailbox.unreadCount : nil,
      totalCount: includeCounts ? mailbox.messages().count : nil
    )
    return MailboxSnapshot(raw: mailbox, model: model, path: path)
  }

  private func collectMailboxes(
    from account: MailAccount,
    accountRawID: String,
    includeCounts: Bool,
    canonicalInboxPaths: Set<String> = []
  ) -> [MailboxSnapshot] {
    var result: [MailboxSnapshot] = []

    func visit(_ mailbox: MailMailbox, path: [String]) {
      let name = mailbox.name ?? "(unnamed)"
      let fullPath = path + [name]
      result.append(
        makeMailboxSnapshot(
          mailbox,
          accountRawID: accountRawID,
          path: fullPath,
          role: canonicalInboxPaths.contains(fullPath.joined(separator: "\u{1F}")) ? .inbox : nil,
          includeCounts: includeCounts
        )
      )

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
    if query.text != nil {
      // Body-backed search is deliberately rejected by the application layer.
      // Keep the adapter defensive so a direct repository call never loads
      // message.source as part of a summary search.
      return false
    }
    if query.unreadOnly && message.readStatus {
      return false
    }
    if query.flaggedOnly && !message.flaggedStatus {
      return false
    }
    return query.matchesReceivedDate(message.dateReceived)
  }

  private func contains(_ candidate: String?, value: String) -> Bool {
    candidate?.localizedCaseInsensitiveContains(value) ?? false
  }

  private func role(for path: [String]) -> MailboxRole? {
    guard let last = path.last?.lowercased() else { return nil }
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
