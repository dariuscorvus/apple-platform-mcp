import Foundation

public struct MailPolicy: Sendable {
  public enum Mode: String, Codable, Sendable {
    case readOnly = "read_only"

    public init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      guard value == Self.readOnly.rawValue else {
        throw MailError.invalidConfiguration(
          "Only mode=read_only is supported in this release.")
      }
      self = .readOnly
    }
  }

  public enum SendMode: String, Codable, Sendable {
    case denied
    case allowed
    case confirmationRequired = "confirmation_required"
  }

  public enum MutationMode: String, Codable, Sendable {
    case denied
    case allowed
    case confirmationRequired = "confirmation_required"
  }

  public let mode: Mode
  public let sendMode: SendMode
  public let mutationMode: MutationMode
  public let maxResults: Int
  public let maxBodyBytes: Int
  public let maxSendBodyBytes: Int
  public let maxSubjectBytes: Int
  public let maxRecipients: Int
  public let allowedAccountIDs: Set<AccountReference>?
  public let allowedMailboxIDs: Set<MailboxReference>?

  public init(
    mode: Mode = .readOnly,
    sendMode: SendMode = .denied,
    mutationMode: MutationMode = .denied,
    maxResults: Int = 50,
    maxBodyBytes: Int = 262_144,
    maxSendBodyBytes: Int = 262_144,
    maxSubjectBytes: Int = 10_000,
    maxRecipients: Int = 100,
    allowedAccountIDs: Set<AccountReference>? = nil,
    allowedMailboxIDs: Set<MailboxReference>? = nil
  ) {
    self.mode = mode
    self.sendMode = sendMode
    self.mutationMode = mutationMode
    self.maxResults = max(1, maxResults)
    self.maxBodyBytes = max(1, maxBodyBytes)
    self.maxSendBodyBytes = max(1, maxSendBodyBytes)
    self.maxSubjectBytes = max(1, maxSubjectBytes)
    self.maxRecipients = max(1, maxRecipients)
    self.allowedAccountIDs = allowedAccountIDs
    self.allowedMailboxIDs = allowedMailboxIDs
  }

  public static let readOnly = MailPolicy()

  public func accountIsAllowed(_ accountID: AccountReference) -> Bool {
    allowedAccountIDs?.contains(accountID) ?? true
  }

  public func mailboxIsAllowed(_ mailboxID: MailboxReference) -> Bool {
    allowedMailboxIDs?.contains(mailboxID) ?? true
  }

  public func boundedLimit(_ requested: Int?) throws -> Int {
    let limit = requested ?? 20
    guard limit > 0 else {
      throw MailError.invalidInput("limit must be greater than zero")
    }
    return min(limit, maxResults)
  }

  public func validateAccount(_ accountID: AccountReference) throws {
    guard accountIsAllowed(accountID) else {
      throw MailError.policyDenied("The requested account is outside the configured allowlist.")
    }
  }

  public func validateMailbox(_ mailboxID: MailboxReference) throws {
    guard mailboxIsAllowed(mailboxID) else {
      throw MailError.policyDenied("The requested mailbox is outside the configured allowlist.")
    }
  }

  public func validateMutation() throws {
    switch mutationMode {
    case .allowed:
      return
    case .denied:
      throw MailError.policyDenied("Mailbox mutations are disabled by policy.")
    case .confirmationRequired:
      throw MailError.policyDenied("Mailbox mutations require explicit confirmation.")
    }
  }
}
