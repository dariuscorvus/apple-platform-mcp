import CryptoKit
import Foundation

private struct ReferenceEnvelope: Codable {
  let version: Int
  let opaqueValue: String
}

private func decodeReference(_ decoder: Decoder) throws -> (version: Int, opaqueValue: String) {
  let singleValue = try decoder.singleValueContainer()
  if let opaqueValue = try? singleValue.decode(String.self) {
    return (1, opaqueValue)
  }

  let envelope = try ReferenceEnvelope(from: decoder)
  return (envelope.version, envelope.opaqueValue)
}

private func encodeReference(_ encoder: Encoder, opaqueValue: String) throws {
  var singleValue = encoder.singleValueContainer()
  try singleValue.encode(opaqueValue)
}

public struct AccountReference: Codable, Hashable, Sendable {
  public let version: Int
  public let opaqueValue: String

  public init(version: Int = 1, opaqueValue: String) {
    self.version = version
    self.opaqueValue = opaqueValue
  }

  public init(from decoder: Decoder) throws {
    let reference = try decodeReference(decoder)
    self.init(version: reference.version, opaqueValue: reference.opaqueValue)
  }

  public func encode(to encoder: Encoder) throws {
    try encodeReference(encoder, opaqueValue: opaqueValue)
  }
}

public struct MailboxReference: Codable, Hashable, Sendable {
  public let version: Int
  public let opaqueValue: String

  public init(version: Int = 1, opaqueValue: String) {
    self.version = version
    self.opaqueValue = opaqueValue
  }

  public init(from decoder: Decoder) throws {
    let reference = try decodeReference(decoder)
    self.init(version: reference.version, opaqueValue: reference.opaqueValue)
  }

  public func encode(to encoder: Encoder) throws {
    try encodeReference(encoder, opaqueValue: opaqueValue)
  }
}

public struct MessageReference: Codable, Hashable, Sendable {
  public let version: Int
  public let opaqueValue: String

  public init(version: Int = 1, opaqueValue: String) {
    self.version = version
    self.opaqueValue = opaqueValue
  }

  public init(from decoder: Decoder) throws {
    let reference = try decodeReference(decoder)
    self.init(version: reference.version, opaqueValue: reference.opaqueValue)
  }

  public func encode(to encoder: Encoder) throws {
    try encodeReference(encoder, opaqueValue: opaqueValue)
  }
}

public struct AttachmentReference: Codable, Hashable, Sendable {
  public let version: Int
  public let opaqueValue: String

  public init(version: Int = 1, opaqueValue: String) {
    self.version = version
    self.opaqueValue = opaqueValue
  }

  public init(from decoder: Decoder) throws {
    let reference = try decodeReference(decoder)
    self.init(version: reference.version, opaqueValue: reference.opaqueValue)
  }

  public func encode(to encoder: Encoder) throws {
    try encodeReference(encoder, opaqueValue: opaqueValue)
  }
}

/// Versioned reference envelopes keep Apple Mail identifiers out of the public
/// domain model. They are not a security boundary yet. Write capabilities must
/// add authentication before they are exposed to clients.
public enum ReferenceCodec {
  private struct Payload: Codable {
    let kind: String
    let components: [String: String]
  }

  public static func account(rawID: String) -> AccountReference {
    AccountReference(opaqueValue: encode(kind: "account", components: ["id": rawID]))
  }

  public static func mailbox(accountRawID: String, path: [String]) -> MailboxReference {
    MailboxReference(
      opaqueValue: encode(
        kind: "mailbox",
        components: ["account": accountRawID, "path": path.joined(separator: "\u{1F}")]
      )
    )
  }

  public static func message(
    accountRawID: String,
    mailboxPath: [String],
    messageRawID: String
  ) -> MessageReference {
    MessageReference(
      opaqueValue: encode(
        kind: "message",
        components: [
          "account": accountRawID,
          "mailbox": mailboxPath.joined(separator: "\u{1F}"),
          "id": messageRawID,
        ]
      )
    )
  }

  public static func attachment(
    accountRawID: String,
    mailboxPath: [String],
    messageRawID: String,
    attachmentRawID: String
  ) -> AttachmentReference {
    AttachmentReference(
      opaqueValue: encode(
        kind: "attachment",
        components: [
          "account": accountRawID,
          "mailbox": mailboxPath.joined(separator: "\u{1F}"),
          "message": messageRawID,
          "id": attachmentRawID,
        ]
      )
    )
  }

  public static func decode(_ reference: AccountReference) -> [String: String]? {
    guard reference.version == 1 else { return nil }
    return decode(reference.opaqueValue, expectedKind: "account")
  }

  public static func decode(_ reference: MailboxReference) -> [String: String]? {
    guard reference.version == 1 else { return nil }
    return decode(reference.opaqueValue, expectedKind: "mailbox")
  }

  public static func decode(_ reference: MessageReference) -> [String: String]? {
    guard reference.version == 1 else { return nil }
    return decode(reference.opaqueValue, expectedKind: "message")
  }

  public static func decode(_ reference: AttachmentReference) -> [String: String]? {
    guard reference.version == 1 else { return nil }
    return decode(reference.opaqueValue, expectedKind: "attachment")
  }

  private static func encode(kind: String, components: [String: String]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(Payload(kind: kind, components: components)) else {
      return "r1_invalid"
    }

    return "r1_"
      + data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func decode(_ value: String, expectedKind: String) -> [String: String]? {
    guard value.hasPrefix("r1_") else { return nil }
    var encoded = String(value.dropFirst(3))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)

    guard
      let data = Data(base64Encoded: encoded),
      let payload = try? JSONDecoder().decode(Payload.self, from: data),
      payload.kind == expectedKind
    else {
      return nil
    }

    return payload.components
  }
}

public struct MailAddress: Codable, Hashable, Sendable {
  public let address: String
  public let displayName: String?

  public init(address: String, displayName: String? = nil) {
    self.address = address
    self.displayName = displayName
  }

  public static func parse(_ raw: String?) -> MailAddress? {
    guard let raw, !raw.isEmpty else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
      let displayName = String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
      let address = String(trimmed[trimmed.index(after: open)..<close])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return MailAddress(address: address, displayName: displayName.isEmpty ? nil : displayName)
    }

    return MailAddress(address: trimmed)
  }
}

public enum MailAddressValidator {
  public static func isValid(_ value: String) -> Bool {
    let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !address.isEmpty,
      address == value,
      address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      address.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }),
      address.filter({ $0 == "@" }).count == 1,
      let at = address.firstIndex(of: "@")
    else {
      return false
    }
    let local = address[..<at]
    let domain = address[address.index(after: at)...]
    guard !local.isEmpty, !domain.isEmpty, domain.first != ".", domain.last != "." else {
      return false
    }
    return !domain.contains("..") && !domain.contains("<") && !domain.contains(">")
  }
}

public struct MailSendRequest: Codable, Equatable, Sendable {
  public let accountID: AccountReference
  public let fromIdentity: String
  public let to: [MailAddress]
  public let cc: [MailAddress]
  public let bcc: [MailAddress]
  public let subject: String
  public let body: String

  public init(
    accountID: AccountReference,
    fromIdentity: String,
    to: [MailAddress],
    cc: [MailAddress] = [],
    bcc: [MailAddress] = [],
    subject: String,
    body: String
  ) {
    self.accountID = accountID
    self.fromIdentity = fromIdentity
    self.to = to
    self.cc = cc
    self.bcc = bcc
    self.subject = subject
    self.body = body
  }
}

public struct MailSendResult: Codable, Equatable, Sendable {
  public let accepted: Bool
  public let accountID: AccountReference
  public let fromIdentity: String

  public init(accepted: Bool, accountID: AccountReference, fromIdentity: String) {
    self.accepted = accepted
    self.accountID = accountID
    self.fromIdentity = fromIdentity
  }
}

public struct AccountCapabilities: Codable, Hashable, Sendable {
  public let canRead: Bool
  public let canSearch: Bool

  public init(canRead: Bool = true, canSearch: Bool = true) {
    self.canRead = canRead
    self.canSearch = canSearch
  }
}

public struct MailAccountModel: Codable, Hashable, Sendable {
  public let id: AccountReference
  public let displayName: String
  public let emailAddresses: [String]
  public let enabled: Bool
  public let capabilities: AccountCapabilities

  public init(
    id: AccountReference,
    displayName: String,
    emailAddresses: [String],
    enabled: Bool,
    capabilities: AccountCapabilities = .init()
  ) {
    self.id = id
    self.displayName = displayName
    self.emailAddresses = emailAddresses
    self.enabled = enabled
    self.capabilities = capabilities
  }
}

public enum MailboxRole: String, Codable, Hashable, Sendable {
  case inbox
  case drafts
  case sent
  case archive
  case trash
  case junk
  case custom
}

public struct Mailbox: Codable, Hashable, Sendable {
  public let id: MailboxReference
  public let accountID: AccountReference
  public let name: String
  public let path: [String]
  public let role: MailboxRole?
  public let unreadCount: Int?
  public let totalCount: Int?

  public init(
    id: MailboxReference,
    accountID: AccountReference,
    name: String,
    path: [String],
    role: MailboxRole?,
    unreadCount: Int?,
    totalCount: Int?
  ) {
    self.id = id
    self.accountID = accountID
    self.name = name
    self.path = path
    self.role = role
    self.unreadCount = unreadCount
    self.totalCount = totalCount
  }
}

public struct MailMessageSummary: Codable, Hashable, Sendable {
  public let id: MessageReference
  public let accountID: AccountReference
  public let mailboxID: MailboxReference
  public let subject: String?
  public let sender: MailAddress?
  public let recipients: [MailAddress]
  public let receivedAt: Date?
  public let sentAt: Date?
  public let isRead: Bool
  public let isFlagged: Bool
  public let hasAttachments: Bool
  public let size: Int?

  public init(
    id: MessageReference,
    accountID: AccountReference,
    mailboxID: MailboxReference,
    subject: String?,
    sender: MailAddress?,
    recipients: [MailAddress],
    receivedAt: Date?,
    sentAt: Date?,
    isRead: Bool,
    isFlagged: Bool,
    hasAttachments: Bool,
    size: Int?
  ) {
    self.id = id
    self.accountID = accountID
    self.mailboxID = mailboxID
    self.subject = subject
    self.sender = sender
    self.recipients = recipients
    self.receivedAt = receivedAt
    self.sentAt = sentAt
    self.isRead = isRead
    self.isFlagged = isFlagged
    self.hasAttachments = hasAttachments
    self.size = size
  }
}

public struct MailBody: Codable, Hashable, Sendable {
  public let plainText: String?
  public let sanitizedHTML: String?
  public let truncated: Bool
  public let originalByteCount: Int?

  public init(
    plainText: String?,
    sanitizedHTML: String? = nil,
    truncated: Bool,
    originalByteCount: Int?
  ) {
    self.plainText = plainText
    self.sanitizedHTML = sanitizedHTML
    self.truncated = truncated
    self.originalByteCount = originalByteCount
  }
}

public struct MailAttachmentMetadata: Codable, Hashable, Sendable {
  public let id: AttachmentReference
  public let filename: String?
  public let mimeType: String?
  public let byteCount: Int?
  public let inline: Bool

  public init(
    id: AttachmentReference,
    filename: String?,
    mimeType: String?,
    byteCount: Int?,
    inline: Bool
  ) {
    self.id = id
    self.filename = filename
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.inline = inline
  }
}

public struct MailMessageRecord: Codable, Hashable, Sendable {
  public let summary: MailMessageSummary
  public let messageIDHeader: String?
  public let inReplyTo: String?
  public let references: [String]
  public let body: MailBody?
  public let attachments: [MailAttachmentMetadata]

  public init(
    summary: MailMessageSummary,
    messageIDHeader: String?,
    inReplyTo: String?,
    references: [String],
    body: MailBody?,
    attachments: [MailAttachmentMetadata]
  ) {
    self.summary = summary
    self.messageIDHeader = messageIDHeader
    self.inReplyTo = inReplyTo
    self.references = references
    self.body = body
    self.attachments = attachments
  }
}

public enum MailBodyFormat: String, Codable, Hashable, Sendable {
  case plainText = "plain_text"
  case sanitizedHTML = "sanitized_html"
  case both
}

public enum MailSearchScope: String, Codable, Hashable, Sendable {
  /// Resolve each eligible account's Mail.app canonical Inbox.
  case inbox
  /// Search only the explicitly supplied mailbox references.
  case mailbox
  /// Explicit broad traversal of eligible accounts and mailboxes.
  case all
}

public struct MailSearchQuery: Codable, Hashable, Sendable {
  public let accountIDs: [AccountReference]?
  public let mailboxIDs: [MailboxReference]?
  public let scope: MailSearchScope
  public let from: String?
  public let to: String?
  public let subject: String?
  public let text: String?
  public let after: Date?
  public let before: Date?
  public let unreadOnly: Bool
  public let flaggedOnly: Bool
  public let limit: Int
  public let cursor: String?

  public init(
    accountIDs: [AccountReference]? = nil,
    mailboxIDs: [MailboxReference]? = nil,
    scope: MailSearchScope = .inbox,
    from: String? = nil,
    to: String? = nil,
    subject: String? = nil,
    text: String? = nil,
    after: Date? = nil,
    before: Date? = nil,
    unreadOnly: Bool = false,
    flaggedOnly: Bool = false,
    limit: Int = 20,
    cursor: String? = nil
  ) {
    self.accountIDs = accountIDs
    self.mailboxIDs = mailboxIDs
    self.scope = scope
    self.from = from
    self.to = to
    self.subject = subject
    self.text = text
    self.after = after
    self.before = before
    self.unreadOnly = unreadOnly
    self.flaggedOnly = flaggedOnly
    self.limit = limit
    self.cursor = cursor
  }

  /// A bounded date search cannot safely include a message without a received
  /// date because its position relative to the requested bounds is unknown.
  public func matchesReceivedDate(_ receivedAt: Date?) -> Bool {
    guard after != nil || before != nil else { return true }
    guard let receivedAt else { return false }
    if let after, receivedAt <= after { return false }
    if let before, receivedAt >= before { return false }
    return true
  }
}

public struct MailSearchPage: Codable, Hashable, Sendable {
  public let messages: [MailMessageSummary]
  public let nextCursor: String?

  public init(messages: [MailMessageSummary], nextCursor: String? = nil) {
    self.messages = messages
    self.nextCursor = nextCursor
  }
}

public enum SearchCursorCodec {
  private struct Payload: Codable {
    let version: Int
    let offset: Int
    let queryHash: String
  }

  public static func encode(query: MailSearchQuery, offset: Int) -> String {
    let payload = Payload(
      version: 1,
      offset: max(0, offset),
      queryHash: queryHash(query)
    )
    guard let data = try? encoder.encode(payload) else { return "c1_invalid" }
    return "c1_"
      + data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public static func decode(_ value: String?, query: MailSearchQuery) throws -> Int {
    guard let value, value.hasPrefix("c1_") else {
      if value == nil { return 0 }
      throw MailError.invalidInput("cursor is invalid")
    }

    var encoded = String(value.dropFirst(3))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)

    guard
      let data = Data(base64Encoded: encoded),
      let payload = try? decoder.decode(Payload.self, from: data),
      payload.version == 1,
      payload.offset >= 0,
      payload.queryHash == queryHash(query)
    else {
      throw MailError.invalidInput("cursor is invalid or does not match the query")
    }

    return payload.offset
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  private static let decoder = JSONDecoder()

  private static func queryHash(_ query: MailSearchQuery) -> String {
    var queryWithoutCursor = query
    queryWithoutCursor = MailSearchQuery(
      accountIDs: query.accountIDs,
      mailboxIDs: query.mailboxIDs,
      scope: query.scope,
      from: query.from,
      to: query.to,
      subject: query.subject,
      text: query.text,
      after: query.after,
      before: query.before,
      unreadOnly: query.unreadOnly,
      flaggedOnly: query.flaggedOnly,
      limit: query.limit,
      cursor: nil
    )

    guard let data = try? encoder.encode(queryWithoutCursor) else { return "invalid" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public protocol MailRepository: Sendable {
  func listAccounts(includeDisabled: Bool) async throws -> [MailAccountModel]

  func listMailboxes(
    accountID: AccountReference,
    includeCounts: Bool
  ) async throws -> [Mailbox]

  func searchMessages(_ query: MailSearchQuery) async throws -> MailSearchPage

  func getMessage(
    id: MessageReference,
    includeBody: Bool,
    bodyFormat: MailBodyFormat,
    includeAttachmentMetadata: Bool,
    maxBodyBytes: Int
  ) async throws -> MailMessageRecord

  func sendMessage(_ request: MailSendRequest) async throws -> MailSendResult
}

/// Adapter boundary used by the application layer. The protocol keeps all
/// Apple-specific implementations replaceable by a fixture or another backend.
public typealias MailAutomationAdapter = MailRepository

public enum MailError: Error, LocalizedError, Equatable, Sendable {
  case permissionDenied
  case mailNotRunning
  case accountNotFound
  case mailboxNotFound
  case messageNotFound
  case ambiguousReference
  case operationTimedOut
  case unsupportedByAccount
  case unsupported(String)
  case bodyTooLarge
  case invalidInput(String)
  case invalidConfiguration(String)
  case policyDenied(String)
  case unknown(String)

  public var code: String {
    switch self {
    case .permissionDenied: return "permissionDenied"
    case .mailNotRunning: return "mailNotRunning"
    case .accountNotFound: return "accountNotFound"
    case .mailboxNotFound: return "mailboxNotFound"
    case .messageNotFound: return "messageNotFound"
    case .ambiguousReference: return "ambiguousReference"
    case .operationTimedOut: return "operationTimedOut"
    case .unsupportedByAccount: return "unsupportedByAccount"
    case .unsupported: return "unsupported"
    case .bodyTooLarge: return "bodyTooLarge"
    case .invalidInput: return "invalidInput"
    case .invalidConfiguration: return "invalidConfiguration"
    case .policyDenied: return "policyDenied"
    case .unknown: return "unknown"
    }
  }

  public var recovery: String? {
    switch self {
    case .permissionDenied:
      return
        "Open System Settings > Privacy & Security > Automation and allow Apple Platform MCP to control Mail."
    case .mailNotRunning:
      return "Open Mail.app and retry the operation."
    case .operationTimedOut:
      return "Retry with a narrower account, mailbox, or result limit."
    case .bodyTooLarge:
      return "Request a smaller body limit or omit the message body."
    case .invalidConfiguration:
      return "Remove the invalid configuration file or correct it using the documented schema."
    default:
      return nil
    }
  }

  public var errorDescription: String? {
    switch self {
    case .permissionDenied: return "Apple Mail automation permission is missing."
    case .mailNotRunning: return "Mail.app is not available."
    case .accountNotFound: return "The requested Mail account was not found."
    case .mailboxNotFound: return "The requested Mailbox was not found."
    case .messageNotFound: return "The requested message was not found."
    case .ambiguousReference: return "The reference resolved to more than one Mail object."
    case .operationTimedOut:
      return "Mail.app did not complete the operation within the time budget."
    case .unsupportedByAccount: return "The Mail account does not support this operation."
    case .unsupported(let message): return message
    case .bodyTooLarge: return "The requested message body exceeds the configured limit."
    case .invalidInput(let message): return message
    case .invalidConfiguration(let message): return message
    case .policyDenied(let message): return message
    case .unknown(let message): return message
    }
  }
}
