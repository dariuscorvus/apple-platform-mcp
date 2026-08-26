import Foundation

public struct MailToolService: Sendable {
  private let repository: any MailRepository
  private let policy: MailPolicy

  public init(repository: any MailRepository, policy: MailPolicy = .readOnly) {
    self.repository = repository
    self.policy = policy
  }

  public var policyMode: MailPolicy.Mode { policy.mode }
  public var sendMode: MailPolicy.SendMode { policy.sendMode }
  public var maxResults: Int { policy.maxResults }
  public var maxBodyBytes: Int { policy.maxBodyBytes }
  public var hasAccountAllowlist: Bool { policy.allowedAccountIDs != nil }
  public var hasMailboxAllowlist: Bool { policy.allowedMailboxIDs != nil }

  public func listAccounts(includeDisabled: Bool) async throws -> [MailAccountModel] {
    try await repository.listAccounts(includeDisabled: includeDisabled).filter {
      policy.accountIsAllowed($0.id)
    }
  }

  public func listMailboxes(
    accountID: AccountReference,
    includeCounts: Bool
  ) async throws -> [Mailbox] {
    try policy.validateAccount(accountID)
    return try await repository.listMailboxes(accountID: accountID, includeCounts: includeCounts)
      .filter { policy.mailboxIsAllowed($0.id) }
  }

  public func searchMessages(_ query: MailSearchQuery) async throws -> MailSearchPage {
    guard query.text == nil else {
      throw MailError.unsupported(
        "Full-text body search is disabled in Mail.app-only V1; use sender or subject filters."
      )
    }
    let boundedLimit = try policy.boundedLimit(query.limit)
    switch query.scope {
    case .inbox:
      guard query.mailboxIDs == nil || query.mailboxIDs?.isEmpty == true else {
        throw MailError.invalidInput("mailbox_ids requires scope=mailbox")
      }
    case .mailbox:
      guard let mailboxIDs = query.mailboxIDs, !mailboxIDs.isEmpty else {
        throw MailError.invalidInput("scope=mailbox requires mailbox_ids")
      }
    case .all:
      guard query.mailboxIDs == nil || query.mailboxIDs?.isEmpty == true else {
        throw MailError.invalidInput("mailbox_ids cannot be combined with scope=all")
      }
    }
    for accountID in query.accountIDs ?? [] {
      try policy.validateAccount(accountID)
    }
    for mailboxID in query.mailboxIDs ?? [] {
      try policy.validateMailbox(mailboxID)
    }

    let scopedAccountIDs =
      query.accountIDs
      ?? policy.allowedAccountIDs?.sorted {
        $0.opaqueValue < $1.opaqueValue
      }
    let scopedMailboxIDs =
      query.mailboxIDs
      ?? policy.allowedMailboxIDs?.sorted {
        $0.opaqueValue < $1.opaqueValue
      }

    let boundedQuery = MailSearchQuery(
      accountIDs: scopedAccountIDs,
      mailboxIDs: scopedMailboxIDs,
      scope: query.scope,
      from: query.from,
      to: query.to,
      subject: query.subject,
      text: query.text,
      after: query.after,
      before: query.before,
      unreadOnly: query.unreadOnly,
      flaggedOnly: query.flaggedOnly,
      limit: boundedLimit,
      cursor: query.cursor
    )
    let page = try await repository.searchMessages(boundedQuery)
    return MailSearchPage(
      messages: page.messages.filter {
        policy.accountIsAllowed($0.accountID) && policy.mailboxIsAllowed($0.mailboxID)
      },
      nextCursor: page.nextCursor
    )
  }

  public func getMessage(
    id: MessageReference,
    includeBody: Bool,
    bodyFormat: MailBodyFormat,
    includeAttachmentMetadata: Bool,
    maxBodyBytes: Int?
  ) async throws -> MailMessageRecord {
    guard
      let components = ReferenceCodec.decode(id),
      let rawAccountID = components["account"],
      let rawMailboxPath = components["mailbox"]
    else {
      throw MailError.messageNotFound
    }

    // The reference is opaque to clients but still locally inspectable so
    // the policy can reject an out-of-scope account before the adapter call.
    let accountID = ReferenceCodec.account(rawID: rawAccountID)
    try policy.validateAccount(accountID)
    let mailboxID = ReferenceCodec.mailbox(
      accountRawID: rawAccountID,
      path: rawMailboxPath.components(separatedBy: "\u{1F}")
    )
    try policy.validateMailbox(mailboxID)

    let requestedBodyBytes = maxBodyBytes ?? policy.maxBodyBytes
    guard requestedBodyBytes > 0 else {
      throw MailError.invalidInput("max_body_bytes must be greater than zero")
    }

    return try await repository.getMessage(
      id: id,
      includeBody: includeBody,
      bodyFormat: bodyFormat,
      includeAttachmentMetadata: includeAttachmentMetadata,
      maxBodyBytes: min(requestedBodyBytes, policy.maxBodyBytes)
    )
  }

  public func sendMessage(_ request: MailSendRequest) async throws -> MailSendResult {
    switch policy.sendMode {
    case .allowed:
      break
    case .denied:
      throw MailError.policyDenied("Sending is disabled by policy.")
    case .confirmationRequired:
      throw MailError.policyDenied("Sending requires explicit confirmation.")
    }

    try policy.validateAccount(request.accountID)
    let accounts = try await repository.listAccounts(includeDisabled: true)
    guard let account = accounts.first(where: { $0.id == request.accountID }) else {
      throw MailError.accountNotFound
    }
    guard account.enabled else {
      throw MailError.policyDenied("Sending from a disabled account is not allowed.")
    }
    guard !request.fromIdentity.isEmpty,
      account.emailAddresses.contains(where: {
        $0.localizedCaseInsensitiveCompare(request.fromIdentity) == .orderedSame
      })
    else {
      throw MailError.policyDenied("from_identity must belong to the selected Mail.app account.")
    }

    let recipients = request.to + request.cc + request.bcc
    guard !recipients.isEmpty else {
      throw MailError.invalidInput("At least one recipient is required.")
    }
    guard recipients.count <= policy.maxRecipients else {
      throw MailError.invalidInput("The recipient list exceeds the configured limit.")
    }
    guard recipients.allSatisfy({ MailAddressValidator.isValid($0.address) }) else {
      throw MailError.invalidInput("Every recipient must be a valid email address.")
    }

    let subjectBytes = request.subject.data(using: .utf8)?.count ?? 0
    guard subjectBytes <= policy.maxSubjectBytes else {
      throw MailError.invalidInput("The subject exceeds the configured limit.")
    }
    let bodyBytes = request.body.data(using: .utf8)?.count ?? 0
    guard bodyBytes <= policy.maxSendBodyBytes else {
      throw MailError.bodyTooLarge
    }

    return try await repository.sendMessage(request)
  }
}
