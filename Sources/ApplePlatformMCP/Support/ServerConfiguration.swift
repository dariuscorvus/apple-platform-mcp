import Foundation

/// Local configuration for the first read-only release.
///
/// The file is optional. Missing configuration always means read-only defaults.
/// References are copied from `mail_list_accounts` and
/// `mail_list_mailboxes`; they are not account names or provider credentials.
public struct MailServerConfiguration: Codable, Equatable, Sendable {
  public let mode: MailPolicy.Mode
  public let maxResults: Int
  public let maxBodyBytes: Int
  public let allowedAccountIDs: Set<AccountReference>?
  public let allowedMailboxIDs: Set<MailboxReference>?

  public static let `default` = MailServerConfiguration()

  public static var defaultURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/apple-platform-mcp/config.json")
  }

  public init(
    mode: MailPolicy.Mode = .readOnly,
    maxResults: Int = 50,
    maxBodyBytes: Int = 262_144,
    allowedAccountIDs: Set<AccountReference>? = nil,
    allowedMailboxIDs: Set<MailboxReference>? = nil
  ) {
    self.mode = mode
    self.maxResults = max(1, maxResults)
    self.maxBodyBytes = max(1, maxBodyBytes)
    self.allowedAccountIDs = allowedAccountIDs
    self.allowedMailboxIDs = allowedMailboxIDs
  }

  public var policy: MailPolicy {
    MailPolicy(
      mode: mode,
      maxResults: maxResults,
      maxBodyBytes: maxBodyBytes,
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
    case maxResults = "max_results"
    case maxBodyBytes = "max_body_bytes"
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
      maxResults: try container.decodeIfPresent(Int.self, forKey: .maxResults) ?? 50,
      maxBodyBytes: try container.decodeIfPresent(Int.self, forKey: .maxBodyBytes) ?? 262_144,
      allowedAccountIDs: try container.decodeIfPresent(
        Set<AccountReference>.self, forKey: .allowedAccountIDs),
      allowedMailboxIDs: try container.decodeIfPresent(
        Set<MailboxReference>.self, forKey: .allowedMailboxIDs)
    )
  }
}
