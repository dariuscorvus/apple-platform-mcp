import Foundation

/// Array positions are not identities. Missing and duplicate Mail IDs are
/// deliberately unavailable for subsequent export or mutation.
public enum MailAttachmentIdentity {
  public static func uniqueIndices(_ identifiers: [String?]) -> [Int] {
    var counts: [String: Int] = [:]
    for case let identifier? in identifiers where !identifier.isEmpty {
      counts[identifier, default: 0] += 1
    }
    return identifiers.indices.filter { index in
      guard let identifier = identifiers[index], !identifier.isEmpty else { return false }
      return counts[identifier] == 1
    }
  }
}
