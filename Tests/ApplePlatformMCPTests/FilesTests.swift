import CryptoKit
import Foundation
import MCP
import Testing

#if !XCODE_COMBINED_TEST_TARGET
  @testable import ApplePlatformMCPKit
#endif

private struct LocalFilesAdapter: FilesFileSystem {
  var recorder: FilesCoordinationRecorder? = nil
  func validateCloudRoot(_ url: URL) throws {}
  func coordinated<T>(_ roots: [URL], writing: Bool, metadataOnly: Bool, _ body: () throws -> T)
    throws -> T
  {
    recorder?.record(metadataOnly)
    return try body()
  }
  func requestDownload(_ url: URL) throws {}
  func trash(_ url: URL) throws {
    try FileManager.default.moveItem(
      at: url, to: url.deletingLastPathComponent().appendingPathComponent("fixture-trashed"))
  }
}
private struct FilesFixture {
  let base: URL
  let root: URL
  let store: URL
  init() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    root = base.appendingPathComponent("root")
    store = base.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  func service(allowed: Bool = true, quota: Int64 = 10_000_000, trash: Bool = false)
    -> FilesToolService
  {
    FilesToolService(
      roots: [.init(id: "test", name: "Fixture", path: root.path)],
      policy: .init(
        mutationMode: allowed ? .allowed : .denied, trashEnabled: trash, stagingQuota: quota),
      storageURL: store, fileSystem: LocalFilesAdapter())
  }
  func cleanup() { try? FileManager.default.removeItem(at: base) }
  func rootID(_ service: FilesToolService) async throws -> String {
    let value = try await service.call("icloud_list_roots")
    return try #require(value.arrayValue?.first?.objectValue?["item_id"]?.stringValue)
  }
}
private func hash(_ bytes: Data) -> String {
  SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
private func text(_ value: Value, _ key: String) throws -> String {
  try #require(value.objectValue?[key]?.stringValue)
}
private func failure(_ code: String, _ body: () async throws -> Value) async {
  do {
    _ = try await body()
    Issue.record("Expected \(code)")
  } catch let error as FilesError { #expect(error.code == code) } catch {
    Issue.record("Unexpected \(error)")
  }
}
@Suite("iCloud Files isolated fixtures")
struct FilesTests {
  @Test func configurationDefaults() throws {
    let config = try JSONDecoder().decode(MailServerConfiguration.self, from: Data("{}".utf8))
    #expect(config.icloudRoots.isEmpty)
    #expect(config.icloudMutationMode == .denied)
    #expect(!config.icloudTrashEnabled)
    let configured = try JSONDecoder().decode(
      MailServerConfiguration.self,
      from: Data(
        """
        {"icloud_roots":[{"id":"a","name":"Test","path":"/a"}],"icloud_mutation_mode":"allowed","icloud_trash_enabled":true,"icloud_staging_quota_bytes":123}
        """.utf8))
    #expect(configured.icloudRoots.count == 1)
    #expect(configured.icloudStagingQuotaBytes == 123)
  }
  @Test func binaryRestartAndRetries() async throws {
    let f = try FilesFixture()
    defer { f.cleanup() }
    var service = f.service()
    let root = try await f.rootID(service)
    let bytes = Data((0..<700_123).map { UInt8($0 % 251) })
    let begin: [String: Value] = [
      "parent_id": .string(root), "name": .string("binary.dat"), "size": .int(bytes.count),
      "sha256": .string(hash(bytes)), "idempotency_key": .string("begin"),
    ]
    let started = try await service.call("icloud_begin_upload", arguments: begin)
    #expect(try await service.call("icloud_begin_upload", arguments: begin) == started)
    let upload = try text(started, "upload_id")
    for offset in stride(from: 0, to: bytes.count, by: FilesToolService.chunkSize) {
      let chunk = bytes.subdata(in: offset..<min(bytes.count, offset + FilesToolService.chunkSize))
      let args: [String: Value] = [
        "upload_id": .string(upload), "offset": .int(offset),
        "data": .string(chunk.base64EncodedString()), "idempotency_key": .string("chunk-\(offset)"),
      ]
      _ = try await service.call("icloud_upload_chunk", arguments: args)
      _ = try await service.call("icloud_upload_chunk", arguments: args)
      service = f.service()  // reload persisted state and references after every chunk
      var duplicate = args
      duplicate["idempotency_key"] = .string("retry-\(offset)")
      _ = try await service.call("icloud_upload_chunk", arguments: duplicate)
    }
    let commit: [String: Value] = [
      "upload_id": .string(upload), "idempotency_key": .string("commit"),
    ]
    let item = try await service.call("icloud_commit_upload", arguments: commit)
    service = f.service()
    #expect(try await service.call("icloud_commit_upload", arguments: commit) == item)
    #expect(try Data(contentsOf: f.root.appendingPathComponent("binary.dat")) == bytes)
    let id = try text(item, "item_id")
    let revision = try text(item, "revision")
    var downloaded = Data()
    for offset in stride(from: 0, to: bytes.count, by: FilesToolService.chunkSize) {
      let result = try await service.call(
        "icloud_read_file",
        arguments: ["item_id": .string(id), "revision": .string(revision), "offset": .int(offset)])
      downloaded.append(try #require(Data(base64Encoded: text(result, "data"))))
    }
    #expect(downloaded == bytes)
    await failure("idempotency_key_reused") {
      var changed = begin
      changed["name"] = .string("other")
      return try await service.call("icloud_begin_upload", arguments: changed)
    }
  }
  @Test func containmentPolicyAndPagination() async throws {
    let f = try FilesFixture()
    defer { f.cleanup() }
    let service = f.service()
    let root = try await f.rootID(service)
    for n in ["a", "b", "c"] { try Data(n.utf8).write(to: f.root.appendingPathComponent(n)) }
    let first = try await service.call(
      "icloud_list_items", arguments: ["item_id": .string(root), "limit": .int(2)])
    #expect(first.objectValue?["items"]?.arrayValue?.count == 2)
    let cursor = try text(first, "next_cursor")
    let second = try await service.call(
      "icloud_list_items",
      arguments: ["item_id": .string(root), "cursor": .string(cursor), "limit": .int(2)])
    #expect(second.objectValue?["items"]?.arrayValue?.count == 1)
    for name in ["../escape", "/tmp/escape", ".", "..", "a/b"] {
      await failure("invalid_name") {
        try await service.call(
          "icloud_create_folder",
          arguments: [
            "parent_id": .string(root), "name": .string(name), "idempotency_key": .string(name),
          ])
      }
    }
    let denied = f.service(allowed: false)
    await failure("policy_denied") {
      try await denied.call(
        "icloud_create_folder",
        arguments: [
          "parent_id": .string(root), "name": .string("denied"),
          "idempotency_key": .string("denied"),
        ])
    }
    await failure("invalid_reference") {
      try await service.call("icloud_get_item", arguments: ["item_id": .string(root + "x")])
    }
    try FileManager.default.createSymbolicLink(
      at: f.root.appendingPathComponent("escape"), withDestinationURL: f.base)
    await failure("symlink_in_tree") {
      try await service.call("icloud_get_item", arguments: ["item_id": .string(root)])
    }
  }
  @Test func managementRevisionsAndTrash() async throws {
    let f = try FilesFixture()
    defer { f.cleanup() }
    let service = f.service(trash: true)
    let root = try await f.rootID(service)
    let folder = try await service.call(
      "icloud_create_folder",
      arguments: [
        "parent_id": .string(root), "name": .string("folder"), "idempotency_key": .string("folder"),
      ])
    let id = try text(folder, "item_id")
    let rev = try text(folder, "revision")
    try Data("descendant".utf8).write(to: f.root.appendingPathComponent("folder/child"))
    await failure("stale_revision") {
      try await service.call(
        "icloud_rename_item",
        arguments: [
          "item_id": .string(id), "revision": .string(rev), "name": .string("renamed"),
          "idempotency_key": .string("stale"),
        ])
    }
    let current = try await service.call("icloud_get_item", arguments: ["item_id": .string(id)])
    let copy = try await service.call(
      "icloud_copy_item",
      arguments: [
        "item_id": .string(id), "revision": .string(text(current, "revision")),
        "parent_id": .string(root), "name": .string("copy"), "idempotency_key": .string("copy"),
      ])
    #expect(
      FileManager.default.fileExists(atPath: f.root.appendingPathComponent("copy/child").path))
    let renamed = try await service.call(
      "icloud_rename_item",
      arguments: [
        "item_id": .string(text(copy, "item_id")), "revision": .string(text(copy, "revision")),
        "name": .string("renamed"), "idempotency_key": .string("rename"),
      ])
    let moved = try await service.call(
      "icloud_move_item",
      arguments: [
        "item_id": .string(text(renamed, "item_id")),
        "revision": .string(text(renamed, "revision")), "parent_id": .string(id),
        "name": .string("moved"), "idempotency_key": .string("move"),
      ])
    _ = try await service.call(
      "icloud_trash_item",
      arguments: [
        "item_id": .string(text(moved, "item_id")), "revision": .string(text(moved, "revision")),
        "idempotency_key": .string("trash"),
      ])
    let rootMeta = try await service.call("icloud_get_item", arguments: ["item_id": .string(root)])
    await failure("root_protected") {
      try await service.call(
        "icloud_trash_item",
        arguments: [
          "item_id": .string(root), "revision": .string(text(rootMeta, "revision")),
          "idempotency_key": .string("root"),
        ])
    }
    let denied = f.service(trash: false)
    await failure("policy_denied") {
      try await denied.call(
        "icloud_trash_item",
        arguments: [
          "item_id": .string(id), "revision": .string(rev),
          "idempotency_key": .string("trash-denied"),
        ])
    }
  }
  @Test func uploadFailuresAndReplacement() async throws {
    let f = try FilesFixture()
    defer { f.cleanup() }
    let service = f.service(quota: 4)
    let root = try await f.rootID(service)
    let args: [String: Value] = [
      "parent_id": .string(root), "name": .string("file"), "size": .int(4),
      "sha256": .string(hash(Data("abcd".utf8))), "idempotency_key": .string("begin"),
    ]
    let started = try await service.call("icloud_begin_upload", arguments: args)
    let upload = try text(started, "upload_id")
    await failure("staging_quota_exceeded") {
      var a = args
      a["idempotency_key"] = .string("quota")
      return try await service.call("icloud_begin_upload", arguments: a)
    }
    await failure("upload_incomplete") {
      try await service.call(
        "icloud_commit_upload",
        arguments: ["upload_id": .string(upload), "idempotency_key": .string("incomplete")])
    }
    _ = try await service.call(
      "icloud_upload_chunk",
      arguments: [
        "upload_id": .string(upload), "offset": .int(0),
        "data": .string(Data("xxxx".utf8).base64EncodedString()), "idempotency_key": .string("bad"),
      ])
    await failure("checksum_mismatch") {
      try await service.call(
        "icloud_commit_upload",
        arguments: ["upload_id": .string(upload), "idempotency_key": .string("checksum")])
    }
    await failure("chunk_retry_mismatch") {
      try await service.call(
        "icloud_upload_chunk",
        arguments: [
          "upload_id": .string(upload), "offset": .int(0),
          "data": .string(Data("abcd".utf8).base64EncodedString()),
          "idempotency_key": .string("mismatch"),
        ])
    }
    _ = try await service.call(
      "icloud_abort_upload",
      arguments: ["upload_id": .string(upload), "idempotency_key": .string("abort")])
    try Data("old".utf8).write(to: f.root.appendingPathComponent("file"))
    let listing = try await service.call("icloud_list_items", arguments: ["item_id": .string(root)])
    let item = try #require(listing.objectValue?["items"]?.arrayValue?.first)
    var replace = args
    replace["idempotency_key"] = .string("replace")
    replace["item_id"] = .string(try text(item, "item_id"))
    replace["revision"] = .string(try text(item, "revision"))
    let replacement = try await service.call("icloud_begin_upload", arguments: replace)
    let replacementID = try text(replacement, "upload_id")
    _ = try await service.call(
      "icloud_upload_chunk",
      arguments: [
        "upload_id": .string(replacementID), "offset": .int(0),
        "data": .string(Data("abcd".utf8).base64EncodedString()),
        "idempotency_key": .string("replacement-chunk"),
      ])
    _ = try await service.call(
      "icloud_commit_upload",
      arguments: [
        "upload_id": .string(replacementID), "idempotency_key": .string("replacement-commit"),
      ])
    #expect(try Data(contentsOf: f.root.appendingPathComponent("file")) == Data("abcd".utf8))
    await failure("name_collision") {
      var a = args
      a["idempotency_key"] = .string("collision")
      return try await service.call("icloud_begin_upload", arguments: a)
    }
  }
  @Test func invalidRootsAndNoImplicitCreation() async throws {
    let f = try FilesFixture()
    defer { f.cleanup() }
    let missing = f.base.appendingPathComponent("missing")
    let absent = FilesToolService(
      roots: [.init(id: "missing", name: "Missing", path: missing.path)], storageURL: f.store,
      fileSystem: LocalFilesAdapter())
    await failure("root_unavailable") { try await absent.call("icloud_list_roots") }
    #expect(!FileManager.default.fileExists(atPath: missing.path))
    let overlap = FilesToolService(
      roots: [
        .init(id: "a", name: "A", path: f.root.path), .init(id: "b", name: "B", path: f.root.path),
      ], storageURL: f.store, fileSystem: LocalFilesAdapter())
    await failure("overlapping_roots") { try await overlap.call("icloud_list_roots") }
    let empty = FilesToolService(storageURL: f.store, fileSystem: LocalFilesAdapter())
    #expect(try await empty.call("icloud_list_roots") == .array([]))
  }
}

private struct SimulatedCloudAdapter: FilesFileSystem {
  var recorder: FilesCoordinationRecorder? = nil
  let pending: Bool
  let conflicts: Bool
  func validateCloudRoot(_ url: URL) throws {}
  func cloudStatus(_ url: URL) throws -> FilesCloudStatus {
    .init(
      ubiquitous: true,
      downloading: pending
        ? URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue
        : URLUbiquitousItemDownloadingStatus.current.rawValue,
      uploading: false, uploaded: false, conflicts: conflicts)
  }
  func coordinated<T>(_ roots: [URL], writing: Bool, metadataOnly: Bool, _ body: () throws -> T)
    throws -> T
  {
    recorder?.record(metadataOnly)
    return try body()
  }
  func requestDownload(_ url: URL) throws {}
  func trash(_ url: URL) throws { throw FilesError("fixture_no_trash") }
}
extension FilesTests {
  @Test func cloudConflictAndPendingDownload() async throws {
    let f = try FilesFixture()
    defer { f.cleanup() }
    try Data("test".utf8).write(to: f.root.appendingPathComponent("file.txt"))
    let local = f.service()
    let root = try await f.rootID(local)
    let page = try await local.call("icloud_list_items", arguments: ["item_id": .string(root)])
    let item = try #require(page.objectValue?["items"]?.arrayValue?.first)
    let id = try text(item, "item_id")
    let revision = try text(item, "revision")
    func cloud(pending: Bool, conflicts: Bool) -> FilesToolService {
      FilesToolService(
        roots: [.init(id: "test", name: "Fixture", path: f.root.path)],
        policy: .init(mutationMode: .allowed), storageURL: f.store,
        fileSystem: SimulatedCloudAdapter(pending: pending, conflicts: conflicts))
    }
    let pending = cloud(pending: true, conflicts: false)
    let download = try await pending.call(
      "icloud_download_item", arguments: ["item_id": .string(id)])
    #expect(try text(download, "status") == "download_pending")
    let read = try await pending.call(
      "icloud_read_file", arguments: ["item_id": .string(id), "revision": .string(revision)])
    #expect(read.objectValue?["retryable"]?.boolValue == true)
    let conflicting = cloud(pending: false, conflicts: true)
    await failure("unresolved_conflict") {
      try await conflicting.call(
        "icloud_rename_item",
        arguments: [
          "item_id": .string(id), "revision": .string(revision), "name": .string("rename"),
          "idempotency_key": .string("conflict"),
        ])
    }
    #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("file.txt").path))
  }
  @Test func expiryAndInterruptedAppendRecovery() async throws {
    let f = try FilesFixture()
    defer { f.cleanup() }
    let service = f.service()
    let root = try await f.rootID(service)
    let begun = try await service.call(
      "icloud_begin_upload",
      arguments: [
        "parent_id": .string(root), "name": .string("file"), "size": .int(4),
        "sha256": .string(hash(Data("abcd".utf8))), "idempotency_key": .string("begin"),
      ])
    let id = try text(begun, "upload_id")
    let part = f.store.appendingPathComponent(id + ".part")
    try Data("unrecorded-interrupted-append".utf8).write(to: part)
    let restarted = f.service()
    _ = try await restarted.call("icloud_get_upload_status", arguments: ["upload_id": .string(id)])
    #expect(try Data(contentsOf: part).isEmpty)
    let stateURL = f.store.appendingPathComponent("state.json")
    var state = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
    var uploads = try #require(state["uploads"] as? [String: [String: Any]])
    uploads[id]?["created"] = Date().addingTimeInterval(-90_000).timeIntervalSinceReferenceDate
    state["uploads"] = uploads
    try JSONSerialization.data(withJSONObject: state).write(to: stateURL, options: .atomic)
    let expired = try await service.call(
      "icloud_get_upload_status", arguments: ["upload_id": .string(id)])
    #expect(try text(expired, "status") == "expired")
    #expect(!FileManager.default.fileExists(atPath: part.path))
  }
  @Test func recursiveSearchAndStaleCursor() async throws {
    let f = try FilesFixture()
    defer { f.cleanup() }
    let service = f.service()
    let root = try await f.rootID(service)
    try FileManager.default.createDirectory(
      at: f.root.appendingPathComponent("nested"), withIntermediateDirectories: false)
    for n in ["one.txt", "two.txt", "skip.bin"] {
      try Data().write(to: f.root.appendingPathComponent("nested/" + n))
    }
    let result = try await service.call(
      "icloud_search_items",
      arguments: ["item_id": .string(root), "query": .string("txt"), "limit": .int(1)])
    #expect(result.objectValue?["items"]?.arrayValue?.count == 1)
    let cursor = try text(result, "next_cursor")
    try Data("changed".utf8).write(to: f.root.appendingPathComponent("nested/one.txt"))
    await failure("stale_cursor") {
      try await service.call(
        "icloud_search_items",
        arguments: ["item_id": .string(root), "query": .string("txt"), "cursor": .string(cursor)])
    }
  }
  @Test func realFoundationCoordination() async throws {
    let f = try FilesFixture()
    defer { f.cleanup() }
    let adapter = FoundationFilesFileSystem()
    let result = try adapter.coordinated([f.root], writing: true) {
      try Data("coordinated".utf8).write(to: f.root.appendingPathComponent("file"))
      return 42
    }
    #expect(result == 42)
  }
}

extension FilesTests {
  @Test func authenticatedTraversalAndSymlinkSwap() async throws {
    let f = try FilesFixture()
    defer { f.cleanup() }
    let service = f.service()
    let rootID = try await f.rootID(service)
    let state = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: f.store.appendingPathComponent("state.json"))) as? [String: Any])
    let encodedSecret = try #require(state["secret"] as? String)
    let secret = try #require(Data(base64Encoded: encodedSecret))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let context = try encoder.encode([ICloudRoot(id: "test", name: "Fixture", path: f.root.path)])
    let key = SymmetricKey(data: Data(SHA256.hash(data: secret + context)))
    for path in ["../outside", "/absolute", "a/../../outside"] {
      let data = try JSONSerialization.data(withJSONObject: ["root": "test", "path": path])
      let signature = Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
      let forged = data.base64EncodedString() + "." + signature.base64EncodedString()
      await failure("invalid_reference") {
        try await service.call("icloud_get_item", arguments: ["item_id": .string(forged)])
      }
    }
    try Data("inside".utf8).write(to: f.root.appendingPathComponent("file"))
    let listing = try await service.call(
      "icloud_list_items", arguments: ["item_id": .string(rootID)])
    let item = try #require(listing.objectValue?["items"]?.arrayValue?.first)
    try FileManager.default.removeItem(at: f.root.appendingPathComponent("file"))
    try FileManager.default.createSymbolicLink(
      at: f.root.appendingPathComponent("file"), withDestinationURL: f.base)
    await failure("symlink_escape") {
      try await service.call(
        "icloud_get_item", arguments: ["item_id": .string(text(item, "item_id"))])
    }
  }
  @Test func emptyFileAndAmbiguousReceipt() async throws {
    let f = try FilesFixture()
    defer { f.cleanup() }
    let service = f.service()
    let root = try await f.rootID(service)
    let begin = try await service.call(
      "icloud_begin_upload",
      arguments: [
        "parent_id": .string(root), "name": .string("empty"), "size": .int(0),
        "sha256": .string(hash(Data())), "idempotency_key": .string("empty"),
      ])
    let args: [String: Value] = [
      "upload_id": .string(try text(begin, "upload_id")),
      "idempotency_key": .string("commit-empty"),
    ]
    let item = try await service.call("icloud_commit_upload", arguments: args)
    let read = try await service.call(
      "icloud_read_file",
      arguments: [
        "item_id": .string(try text(item, "item_id")),
        "revision": .string(try text(item, "revision")),
      ])
    #expect(read.objectValue?["eof"]?.boolValue == true)
    let stateURL = f.store.appendingPathComponent("state.json")
    var state = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
    var receipts = try #require(state["receipts"] as? [String: [String: Any]])
    receipts["commit-empty"]?.removeValue(forKey: "result")
    state["receipts"] = receipts
    try JSONSerialization.data(withJSONObject: state).write(to: stateURL, options: .atomic)
    await failure("operation_indeterminate_inspect_before_retry") {
      try await f.service().call("icloud_commit_upload", arguments: args)
    }
    #expect(try Data(contentsOf: f.root.appendingPathComponent("empty")).isEmpty)
  }
}

extension FilesTests {
  @Test func packageIsOpaqueAndRevisionIncludesItsContents() async throws {
    let f = try FilesFixture()
    defer { f.cleanup() }
    let package = f.root.appendingPathComponent("Opaque.app")
    try FileManager.default.createDirectory(
      at: package.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let internalFile = package.appendingPathComponent("Contents/data")
    try Data("before".utf8).write(to: internalFile)
    let service = f.service()
    let root = try await f.rootID(service)
    let listing = try await service.call("icloud_list_items", arguments: ["item_id": .string(root)])
    let item = try #require(listing.objectValue?["items"]?.arrayValue?.first)
    #expect(try text(item, "kind") == "package")
    let id = try text(item, "item_id")
    let rev = try text(item, "revision")
    await failure("not_folder") {
      try await service.call("icloud_list_items", arguments: ["item_id": .string(id)])
    }
    await failure("not_ordinary_file") {
      try await service.call(
        "icloud_read_file", arguments: ["item_id": .string(id), "revision": .string(rev)])
    }
    try Data("after".utf8).write(to: internalFile)
    await failure("stale_revision") {
      try await service.call(
        "icloud_rename_item",
        arguments: [
          "item_id": .string(id), "revision": .string(rev), "name": .string("New.app"),
          "idempotency_key": .string("package"),
        ])
    }
  }
}

extension FilesTests {
  @Test func caseAliasCannotCreateOverlappingRoots() async throws {
    let f = try FilesFixture()
    defer { f.cleanup() }
    let alias = f.base.appendingPathComponent("ROOT")
    // This attack applies only on case-insensitive volumes.
    guard FileManager.default.fileExists(atPath: alias.path) else { return }
    let service = FilesToolService(
      roots: [
        .init(id: "a", name: "A", path: f.root.path), .init(id: "b", name: "B", path: alias.path),
      ], storageURL: f.store, fileSystem: LocalFilesAdapter())
    do {
      _ = try await service.call("icloud_list_roots")
      Issue.record("Case alias root was accepted")
    } catch let error as FilesError {
      #expect(["overlapping_roots", "symlink_root"].contains(error.code))
    }
  }
}

private final class FilesCoordinationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Bool] = []
  func record(_ metadataOnly: Bool) {
    lock.lock()
    defer { lock.unlock() }
    values.append(metadataOnly)
  }
  var recorded: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}
extension FilesTests {
  @Test func metadataDiscoveryAndPendingReadDoNotWaitForContentCoordination() async throws {
    let f = try FilesFixture()
    defer { f.cleanup() }
    try Data("content".utf8).write(to: f.root.appendingPathComponent("file.txt"))
    let recorder = FilesCoordinationRecorder()
    let roots = [ICloudRoot(id: "test", name: "Fixture", path: f.root.path)]
    let service = FilesToolService(
      roots: roots, storageURL: f.store, fileSystem: LocalFilesAdapter(recorder: recorder))
    let root = try await f.rootID(service)
    _ = try await service.call("icloud_get_item", arguments: ["item_id": .string(root)])
    let page = try await service.call("icloud_list_items", arguments: ["item_id": .string(root)])
    _ = try await service.call(
      "icloud_search_items", arguments: ["item_id": .string(root), "query": .string("file")])
    let item = try #require(page.objectValue?["items"]?.arrayValue?.first)
    let args: [String: Value] = [
      "item_id": .string(try text(item, "item_id")),
      "revision": .string(try text(item, "revision")),
    ]
    _ = try await service.call("icloud_read_file", arguments: args)
    let pending = FilesToolService(
      roots: roots, storageURL: f.store,
      fileSystem: SimulatedCloudAdapter(recorder: recorder, pending: true, conflicts: false))
    let response = try await pending.call("icloud_read_file", arguments: args)
    #expect(try text(response, "status") == "download_pending")
    #expect(recorder.recorded == [true, true, true, false, true])
  }
}
