import Foundation

/// A canonical Inbox candidate obtained from Mail.app's special `inbox`
/// container. Its path is descriptive only; resolution never infers a role
/// from a localized display name.
public struct CanonicalInboxCandidate: Equatable, Sendable {
  public let accountID: AccountReference
  public let mailboxID: MailboxReference
  public let path: [String]

  public init(accountID: AccountReference, mailboxID: MailboxReference, path: [String]) {
    self.accountID = accountID
    self.mailboxID = mailboxID
    self.path = path
  }
}

public enum CanonicalInboxResolver {
  /// Resolve only a candidate explicitly exposed by Mail.app for the account.
  /// An absent or ambiguous mapping is a hard miss rather than a localized
  /// `Inbox`/`Posteingang` name guess.
  public static func resolve(
    accountID: AccountReference,
    candidates: [CanonicalInboxCandidate]
  ) -> CanonicalInboxCandidate? {
    let matches = candidates.filter { $0.accountID == accountID }
    guard !matches.isEmpty else { return nil }
    let deepestPathLength = matches.map(\.path.count).max() ?? 0
    let specificMatches = matches.filter { $0.path.count == deepestPathLength }
    guard specificMatches.count == 1 else { return nil }
    return specificMatches[0]
  }
}
