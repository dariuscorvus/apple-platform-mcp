import Foundation

/// Local configuration for the Mail.app-backed V1 release.
///
/// The file is optional. Missing configuration always means read-only,
/// send-denied, mutation-denied defaults.
/// References are copied from `mail_list_accounts` and
/// `mail_list_mailboxes`; they are not account names or provider credentials.
public struct MailServerConfiguration: Codable, Equatable, Sendable {
  public let mode: MailPolicy.Mode
  public let sendMode: MailPolicy.SendMode
  public let mutationMode: MailPolicy.MutationMode
  public let maxResults: Int
  public let maxBodyBytes: Int
  public let maxSendBodyBytes: Int
  public let maxSubjectBytes: Int
  public let maxRecipients: Int
  public let allowedAccountIDs: Set<AccountReference>?
  public let allowedMailboxIDs: Set<MailboxReference>?

  public static let `default` = MailServerConfiguration()

  public static var defaultURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/apple-platform-mcp/config.json")
  }

  public init(
    mode: MailPolicy.Mode = .readOnly,
    sendMode: MailPolicy.SendMode = .denied,
    mutationMode: MailPolicy.MutationMode = .denied,
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

  public var policy: MailPolicy {
    MailPolicy(
      mode: mode,
      sendMode: sendMode,
      mutationMode: mutationMode,
      maxResults: maxResults,
      maxBodyBytes: maxBodyBytes,
      maxSendBodyBytes: maxSendBodyBytes,
      maxSubjectBytes: maxSubjectBytes,
      maxRecipients: maxRecipients,
      allowedAccountIDs: allowedAccountIDs,
      allowedMailboxIDs: allowedMailboxIDs
    )
  }

  public static func load(
    from url: URL = Self.defaultURL,
    fileManager: FileManager = .default
  ) throws -> MailServerConfiguration {
    guard fileManager.fileExists(atPath: url.path) else {
      return .default
    }

    do {
      let data = try Data(contentsOf: url)
      let configuration = try JSONDecoder().decode(Self.self, from: data)
      guard configuration.mode == .readOnly else {
        throw MailError.invalidConfiguration("Only mode=read_only is supported in this release.")
      }
      return configuration
    } catch let error as MailError {
      throw error
    } catch {
      throw MailError.invalidConfiguration("The configuration file is not valid JSON.")
    }
  }

  private enum CodingKeys: String, CodingKey {
    case mode
    case sendMode = "send_mode"
    case mutationMode = "mutation_mode"
    case maxResults = "max_results"
    case maxBodyBytes = "max_body_bytes"
    case maxSendBodyBytes = "max_send_body_bytes"
    case maxSubjectBytes = "max_subject_bytes"
    case maxRecipients = "max_recipients"
    case allowedAccountIDs = "allowed_account_ids"
    case allowedMailboxIDs = "allowed_mailbox_ids"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let mode = try container.decodeIfPresent(MailPolicy.Mode.self, forKey: .mode) ?? .readOnly
    guard mode == .readOnly else {
      throw MailError.invalidConfiguration("Only mode=read_only is supported in this release.")
    }

    self.init(
      mode: mode,
      sendMode: try container.decodeIfPresent(MailPolicy.SendMode.self, forKey: .sendMode)
        ?? .denied,
      mutationMode: try container.decodeIfPresent(
        MailPolicy.MutationMode.self, forKey: .mutationMode
      ) ?? .denied,
      maxResults: try container.decodeIfPresent(Int.self, forKey: .maxResults) ?? 50,
      maxBodyBytes: try container.decodeIfPresent(Int.self, forKey: .maxBodyBytes) ?? 262_144,
      maxSendBodyBytes: try container.decodeIfPresent(Int.self, forKey: .maxSendBodyBytes)
        ?? 262_144,
      maxSubjectBytes: try container.decodeIfPresent(Int.self, forKey: .maxSubjectBytes) ?? 10_000,
      maxRecipients: try container.decodeIfPresent(Int.self, forKey: .maxRecipients) ?? 100,
      allowedAccountIDs: try container.decodeIfPresent(
        Set<AccountReference>.self, forKey: .allowedAccountIDs),
      allowedMailboxIDs: try container.decodeIfPresent(
        Set<MailboxReference>.self, forKey: .allowedMailboxIDs)
    )
  }
}
