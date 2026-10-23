import Foundation

/// Mail.app evaluates this first pass through an Apple Event `whose` clause.
/// Only simple scriptable properties belong here: ScriptingBridge rejects
/// recipient key paths and arbitrary Foundation predicates. The repository
/// still checks the complete query on the resulting candidate messages.
enum MailSearchPredicate {
  static func make(for query: MailSearchQuery) -> NSPredicate? {
    var filters: [NSPredicate] = []
    // Bind values rather than interpolating user text into predicate syntax.
    if let from = query.from, !from.isEmpty {
      filters.append(NSPredicate(format: "sender CONTAINS[c] %@", from))
    }
    if let subject = query.subject, !subject.isEmpty {
      filters.append(NSPredicate(format: "subject CONTAINS[c] %@", subject))
    }
    // Apple Event dates have whole-second precision. Broaden the native bounds
    // so rounding cannot discard a match; residual checks keep strict bounds.
    if let after = query.after {
      let boundary = Date(timeIntervalSince1970: floor(after.timeIntervalSince1970))
      filters.append(NSPredicate(format: "dateReceived >= %@", boundary as NSDate))
    }
    if let before = query.before {
      let boundary = Date(timeIntervalSince1970: ceil(before.timeIntervalSince1970))
      filters.append(NSPredicate(format: "dateReceived <= %@", boundary as NSDate))
    }
    if query.unreadOnly {
      filters.append(NSPredicate(format: "readStatus == NO"))
    }
    if query.flaggedOnly {
      filters.append(NSPredicate(format: "flaggedStatus == YES"))
    }
    guard !filters.isEmpty else { return nil }
    return filters.count == 1
      ? filters[0] : NSCompoundPredicate(andPredicateWithSubpredicates: filters)
  }
}
