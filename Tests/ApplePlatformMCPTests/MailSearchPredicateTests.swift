import Foundation
import Testing

#if canImport(MailScriptingBridge)
  import MailScriptingBridge
#endif

#if !XCODE_COMBINED_TEST_TARGET
  @testable import ApplePlatformMCPKit
#endif

@Suite("Mail native search filters")
struct MailSearchPredicateTests {
  @Test("text values are literal, Unicode-aware and case-insensitive")
  func literalText() throws {
    for term in ["Accountable", "ÜBER", "O'Reilly", "\" OR TRUEPREDICATE OR \"", "%@", "\\"] {
      let predicate = try #require(MailSearchPredicate.make(for: MailSearchQuery(from: term)))
      #expect(predicate.evaluate(with: ["sender": "prefix \(term.lowercased()) suffix"]))
      #expect(!predicate.evaluate(with: ["sender": "unrelated address"]))
    }
    let subject = try #require(
      MailSearchPredicate.make(for: MailSearchQuery(subject: "Umsatzsteuer")))
    #expect(subject.evaluate(with: ["subject": "Ihre UMSATZSTEUER Unterlagen"]))
    #expect(!subject.evaluate(with: ["subject": "Andere Unterlagen"]))
  }

  @Test("all supported constraints are combined with AND")
  func combinedFilters() throws {
    let query = MailSearchQuery(
      from: "accountable", subject: "Steuer",
      after: Date(timeIntervalSince1970: 100), before: Date(timeIntervalSince1970: 200),
      unreadOnly: true, flaggedOnly: true)
    let predicate = try #require(MailSearchPredicate.make(for: query))
    let matching: [String: Any] = [
      "sender": "ACCOUNTABLE", "subject": "Steuerbescheid",
      "dateReceived": Date(timeIntervalSince1970: 150), "readStatus": false, "flaggedStatus": true,
    ]
    #expect(predicate.evaluate(with: matching))
    for (key, value) in [
      ("sender", "other" as Any), ("subject", "other" as Any),
      ("dateReceived", Date(timeIntervalSince1970: 99) as Any),
      ("dateReceived", Date(timeIntervalSince1970: 201) as Any),
      ("readStatus", true as Any), ("flaggedStatus", false as Any),
    ] {
      var candidate = matching
      candidate[key] = value
      #expect(!predicate.evaluate(with: candidate))
    }
  }

  @Test("native whole-second bounds retain strict fractional-date candidates")
  func dateBoundaries() throws {
    let query = MailSearchQuery(
      after: Date(timeIntervalSince1970: 100.75),
      before: Date(timeIntervalSince1970: 102.25))
    let predicate = try #require(MailSearchPredicate.make(for: query))
    for time in [100.0, 100.75, 100.8, 101.0, 102.2, 102.25, 103.0] {
      let date = Date(timeIntervalSince1970: time)
      // Native filtering is a superset. The repository's original strict
      // matching is still applied before pagination and output.
      if query.matchesReceivedDate(date) {
        #expect(predicate.evaluate(with: ["dateReceived": date]))
      }
    }
    #expect(!query.matchesReceivedDate(query.after))
    #expect(!query.matchesReceivedDate(query.before))
    #expect(!query.matchesReceivedDate(nil))
  }

  @Test("unsupported recipient/body fields do not become native key paths")
  func residualOnlyFilters() throws {
    #expect(MailSearchPredicate.make(for: MailSearchQuery()) == nil)
    #expect(MailSearchPredicate.make(for: MailSearchQuery(to: "person@example.invalid")) == nil)
    #expect(MailSearchPredicate.make(for: MailSearchQuery(text: "body")) == nil)
    #expect(MailSearchPredicate.make(for: MailSearchQuery(from: "", subject: "")) == nil)
    let predicate = try #require(
      MailSearchPredicate.make(
        for:
          MailSearchQuery(from: "accountable", to: "person@example.invalid")))
    #expect(predicate.evaluate(with: ["sender": "accountable"]))
    #expect(!predicate.predicateFormat.contains("toRecipients"))
  }

  @Test("unsupported native predicates fail safely without a Mail query or leaked text")
  func unsupportedNativePredicate() throws {
    let app = try #require(MailApplication(bundleIdentifier: "com.apple.mail"))
    // Creating these specifiers is lazy. Translation of an unsupported key
    // path throws before get sends an Apple Event, so no consent is requested.
    let messages = try #require(app.inbox.messages())
    let previousTimeout = app.timeout
    let predicate = NSPredicate(
      format: "ANY toRecipients.address CONTAINS[c] %@", "private@example.invalid")
    var error: NSError?
    #expect(APSMailSearchMessages(app, messages, predicate, &error) == nil)
    #expect(error?.domain == "APSMailSearch")
    #expect(error?.code == 1)
    #expect(error?.localizedDescription.contains("private@example.invalid") == false)
    #expect(app.timeout == previousTimeout)
    #expect(app.delegate == nil)
  }
}
