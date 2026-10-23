import Testing

#if !XCODE_COMBINED_TEST_TARGET
  @testable import ApplePlatformMCPKit
#endif

@Suite("Mail attachment identity")
struct MailAttachmentIdentityTests {
  @Test("Missing and duplicate IDs never become addressable attachments")
  func invalidIDs() {
    #expect(MailAttachmentIdentity.uniqueIndices([nil, "", "a", "a", "b"]) == [4])
    #expect(MailAttachmentIdentity.uniqueIndices([]).isEmpty)
  }
  @Test("Identity survives reorder and never aliases an array position")
  func reorder() {
    let original: [String?] = ["b", nil, "a"]
    let reordered: [String?] = ["a", "b", nil]
    #expect(MailAttachmentIdentity.uniqueIndices(original).map { original[$0] } == ["b", "a"])
    #expect(MailAttachmentIdentity.uniqueIndices(reordered).map { reordered[$0] } == ["a", "b"])
  }
}
