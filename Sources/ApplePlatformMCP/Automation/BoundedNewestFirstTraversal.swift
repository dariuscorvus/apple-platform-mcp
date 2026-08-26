import Foundation

/// A bounded k-way merge for Mail.app collections that are already ordered
/// newest-first. The caller supplies indexed access so the application asks
/// each source only for the prefix needed for the requested page and one
/// lookahead match. This does not claim a bound on Mail.app's internal Apple
/// Event work while it produces or indexes a collection.
public enum BoundedNewestFirstTraversal {
  public struct Result<Element> {
    public let elements: [Element]
    public let hasMore: Bool
    public let inspected: Int

    public init(elements: [Element], hasMore: Bool, inspected: Int) {
      self.elements = elements
      self.hasMore = hasMore
      self.inspected = inspected
    }
  }

  private struct Candidate<Element> {
    let sourceIndex: Int
    let elementIndex: Int
    let element: Element
    let receivedAt: Date?
  }

  public static func search<Source, Element>(
    sources: [Source],
    offset: Int,
    limit: Int,
    date: (Element) -> Date?,
    matches: (Element) -> Bool,
    elementAt: (Source, Int) -> Element,
    count: (Source) -> Int
  ) -> Result<Element> {
    let boundedOffset = max(0, offset)
    let boundedLimit = max(1, limit)
    var heads: [Candidate<Element>] = []

    for (sourceIndex, source) in sources.enumerated() {
      guard count(source) > 0 else { continue }
      let element = elementAt(source, 0)
      heads.append(
        Candidate(
          sourceIndex: sourceIndex,
          elementIndex: 0,
          element: element,
          receivedAt: date(element)
        )
      )
    }

    var skipped = 0
    var matched: [Element] = []
    var inspected = 0

    while !heads.isEmpty {
      let selectedIndex = heads.indices.min { lhs, rhs in
        isNewer(heads[lhs], than: heads[rhs])
      }!
      let candidate = heads.remove(at: selectedIndex)
      inspected += 1

      if matches(candidate.element) {
        if skipped < boundedOffset {
          skipped += 1
        } else {
          matched.append(candidate.element)
          if matched.count > boundedLimit {
            return Result(
              elements: Array(matched.prefix(boundedLimit)),
              hasMore: true,
              inspected: inspected
            )
          }
        }
      }

      let source = sources[candidate.sourceIndex]
      let nextIndex = candidate.elementIndex + 1
      if nextIndex < count(source) {
        let nextElement = elementAt(source, nextIndex)
        heads.append(
          Candidate(
            sourceIndex: candidate.sourceIndex,
            elementIndex: nextIndex,
            element: nextElement,
            receivedAt: date(nextElement)
          )
        )
      }
    }

    return Result(elements: matched, hasMore: false, inspected: inspected)
  }

  private static func isNewer<Element>(
    _ lhs: Candidate<Element>,
    than rhs: Candidate<Element>
  ) -> Bool {
    switch (lhs.receivedAt, rhs.receivedAt) {
    case (let left?, let right?) where left != right:
      return left > right
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    default:
      if lhs.sourceIndex != rhs.sourceIndex {
        return lhs.sourceIndex < rhs.sourceIndex
      }
      return lhs.elementIndex < rhs.elementIndex
    }
  }
}
