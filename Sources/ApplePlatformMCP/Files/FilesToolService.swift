import CryptoKit
import Darwin
import Foundation
import MCP

/// Serial queue owns filesystem and durable transfer state; never blocks MCP's executor.
public final class FilesToolService: @unchecked Sendable {
  public static let chunkSize = 262_144
  private let queue = DispatchQueue(label: "apple-platform-mcp.files", qos: .utility)
  private let roots: [ICloudRoot]
  private let policy: FilesPolicy
  private let fs: any FilesFileSystem
  private let store: URL
  private let fm = FileManager.default
  private var state: State?
  private var mutationEffectStarted = false
  private struct Reference: Codable {
    let root: String
    let path: String
  }
  private struct Receipt: Codable {
    let fingerprint: String
    var result: Value?
  }
  private struct Upload: Codable {
    let id: String
    let parent: String
    let name: String
    let size: Int64
    let sha256: String
    let item: String?
    let revision: String?
    let created: Date
    var received: Int64
    var status: String
  }
  private struct State: Codable {
    var secret: Data
    var receipts: [String: Receipt] = [:]
    var uploads: [String: Upload] = [:]
  }
  public init(
    roots: [ICloudRoot] = [], policy: FilesPolicy = .init(),
    storageURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/apple-platform-mcp/files"),
    fileSystem: any FilesFileSystem = FoundationFilesFileSystem()
  ) {
    self.roots = roots
    self.policy = policy
    self.store = storageURL
    self.fs = fileSystem
  }
  public func call(_ name: String, arguments: [String: Value] = [:]) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          continuation.resume(
            returning: try self.withStorageLock { try self.execute(name, arguments) })
        } catch let error as FilesError { continuation.resume(throwing: error) } catch {
          continuation.resume(throwing: FilesError("filesystem_unavailable"))
        }
      }
    }
  }
  private func withStorageLock<T>(_ body: () throws -> T) throws -> T {
    try fm.createDirectory(
      at: store, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard try store.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw FilesError("unsafe_staging_directory")
    }
    let fd = open(
      store.appendingPathComponent("service.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw FilesError("staging_unavailable") }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw FilesError("staging_busy_retry") }
    defer { flock(fd, LOCK_UN) }
    state = nil  // other transports/processes may have advanced the durable state
    return try body()
  }
  private func load() throws {
    if state != nil { return }
    try fm.createDirectory(
      at: store, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let values = try store.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true else { throw FilesError("unsafe_staging_directory") }
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path)
    let url = store.appendingPathComponent("state.json")
    if fm.fileExists(atPath: url.path) {
      state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
    } else {
      state = State(secret: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
      try save()
    }
    for (id, upload) in state!.uploads
    where ["committed", "aborted", "expired"].contains(upload.status) {
      try? fm.removeItem(at: chunkURL(id))
    }
    for (id, var upload) in state!.uploads where upload.status == "receiving" {
      if Date().timeIntervalSince(upload.created) > 86_400 {
        upload.status = "expired"
        state!.uploads[id] = upload
        try? fm.removeItem(at: chunkURL(id))
      } else if fm.fileExists(atPath: chunkURL(id).path) {
        let handle = try FileHandle(forWritingTo: chunkURL(id))
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(upload.received))
      }
    }
    try save()
  }
  private func save() throws {
    let data = try JSONEncoder().encode(state!)
    try data.write(to: store.appendingPathComponent("state.json"), options: .atomic)
    try fm.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: store.appendingPathComponent("state.json").path)
  }
  private func chunkURL(_ id: String) -> URL { store.appendingPathComponent(id + ".part") }
  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private func referenceKey() -> SymmetricKey {
    // Changing the configured path behind a stable ID invalidates old capabilities.
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let context = (try? encoder.encode(roots.sorted { $0.id < $1.id })) ?? Data()
    return SymmetricKey(data: Data(SHA256.hash(data: state!.secret + context)))
  }
  private func mac(_ data: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: data, using: referenceKey()))
  }
  private func token(_ ref: Reference) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(ref)
    return data.base64EncodedString() + "." + mac(data).base64EncodedString()
  }
  private func decode(_ token: String) throws -> Reference {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, let data = Data(base64Encoded: String(parts[0])),
      let signature = Data(base64Encoded: String(parts[1])),
      HMAC<SHA256>.isValidAuthenticationCode(
        signature, authenticating: data, using: referenceKey()),
      let ref = try? JSONDecoder().decode(Reference.self, from: data)
    else { throw FilesError("invalid_reference") }
    return ref
  }
  private func validateRoots() throws {
    guard Set(roots.map(\.id)).count == roots.count,
      roots.allSatisfy({ !$0.id.isEmpty && $0.path.hasPrefix("/") })
    else { throw FilesError("invalid_roots") }
    var paths: [String] = []
    var rootIdentities: Set<String> = []
    var ancestorIdentities: Set<String> = []
    for root in roots {
      let url = URL(fileURLWithPath: root.path).standardizedFileURL
      guard url.path == url.resolvingSymlinksInPath().path else { throw FilesError("symlink_root") }
      guard
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey, .isPackageKey])
      else { throw FilesError("root_unavailable") }
      guard v.isDirectory == true, v.isReadable == true, v.isPackage != true else {
        throw FilesError("root_unavailable")
      }
      try fs.validateCloudRoot(url)
      guard !paths.contains(where: { contains($0, url.path) || contains(url.path, $0) }) else {
        throw FilesError("overlapping_roots")
      }
      let identity = try fileIdentity(url)
      var ancestors: Set<String> = []
      var ancestor = url
      while true {
        ancestors.insert(try fileIdentity(ancestor))
        if ancestor.path == "/" { break }
        ancestor.deleteLastPathComponent()
      }
      guard rootIdentities.isDisjoint(with: ancestors), !ancestorIdentities.contains(identity)
      else {
        throw FilesError("overlapping_roots")
      }
      rootIdentities.insert(identity)
      ancestorIdentities.formUnion(ancestors)
      paths.append(url.path)
      guard !contains(url.path, store.resolvingSymlinksInPath().path) else {
        throw FilesError("staging_inside_root")
      }
    }
  }
  private func fileIdentity(_ url: URL) throws -> String {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw FilesError("item_unavailable") }
    return "\(info.st_dev):\(info.st_ino)"
  }
  private func contains(_ parent: String, _ child: String) -> Bool {
    child == parent || child.hasPrefix(parent + "/")
  }
  private func resolve(_ reference: String, protectRoot: Bool = false) throws -> URL {
    let ref = try decode(reference)
    guard let root = roots.first(where: { $0.id == ref.root }), !ref.path.hasPrefix("/"),
      !ref.path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
    else { throw FilesError("invalid_reference") }
    if protectRoot && ref.path.isEmpty { throw FilesError("root_protected") }
    let base = URL(fileURLWithPath: root.path).standardizedFileURL
    let url = ref.path.isEmpty ? base : base.appendingPathComponent(ref.path)
    guard contains(base.path, url.standardizedFileURL.path),
      url.path == url.resolvingSymlinksInPath().path
    else { throw FilesError("symlink_escape") }
    // Packages are opaque: references may name one, never traverse into one.
    var ancestor = url.deletingLastPathComponent()
    while contains(base.path, ancestor.path), ancestor.path != base.path {
      if try ancestor.resourceValues(forKeys: [.isPackageKey]).isPackage == true {
        throw FilesError("package_opaque")
      }
      ancestor.deleteLastPathComponent()
    }
    guard fm.fileExists(atPath: url.path) else { throw FilesError("item_unavailable") }
    return url
  }
  private func reference(_ input: URL) throws -> String {
    let url = input.standardizedFileURL
    guard
      let root = roots.first(where: {
        contains(URL(fileURLWithPath: $0.path).standardizedFileURL.path, url.path)
      })
    else { throw FilesError("outside_roots") }
    let base = URL(fileURLWithPath: root.path).standardizedFileURL.path
    return try token(
      .init(root: root.id, path: url.path == base ? "" : String(url.path.dropFirst(base.count + 1)))
    )
  }
  private func child(_ parent: URL, name: String) throws -> URL {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
      !name.contains(":"), !name.contains("\0"), name.utf8.count <= 255
    else { throw FilesError("invalid_name") }
    let v = try parent.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
    guard v.isDirectory == true, v.isPackage != true else {
      throw FilesError("destination_not_folder")
    }
    let target = parent.appendingPathComponent(name)
    guard target.path == target.resolvingSymlinksInPath().path else {
      throw FilesError("symlink_escape")
    }
    return target
  }
  private func noCollision(_ url: URL) throws {
    guard !fm.fileExists(atPath: url.path), (try? fm.attributesOfItem(atPath: url.path)) == nil
    else { throw FilesError("name_collision") }
  }
  private func descendants(_ url: URL, includingPackages: Bool = false) throws -> [URL] {
    var items: [URL] = []
    func walk(_ folder: URL) throws {
      for item in try fm.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
      ).map(\.standardizedFileURL).sorted(by: { $0.path < $1.path }) {
        let v = try item.resourceValues(forKeys: [
          .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
        ])
        guard v.isSymbolicLink != true else { throw FilesError("symlink_in_tree") }
        if !includingPackages { _ = try resolve(reference(item)) }
        items.append(item)
        if v.isDirectory == true && (includingPackages || v.isPackage != true) { try walk(item) }
      }
    }
    if try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]).isDirectory == true,
      try includingPackages || (url.resourceValues(forKeys: [.isPackageKey]).isPackage != true)
    {
      try walk(url)
    }
    return items
  }
  private func revision(_ url: URL) throws -> String {
    var data = Data()
    for item in [url] + (try descendants(url, includingPackages: true)) {
      var info = stat()
      guard lstat(item.path, &info) == 0 else { throw FilesError("item_unavailable") }
      let row =
        "\(item.path)|\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_mode)|\(info.st_mtimespec.tv_sec)|\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec)|\(info.st_ctimespec.tv_nsec)\n"
      data.append(contentsOf: row.utf8)
    }
    return digest(data)
  }
  private func conflict(_ url: URL, recursive: Bool = false) throws {
    for item in [url] + (recursive ? try descendants(url, includingPackages: true) : []) {
      if try fs.cloudStatus(item).conflicts == true { throw FilesError("unresolved_conflict") }
    }
  }
  private func check(_ url: URL, _ expected: String) throws {
    try conflict(url, recursive: true)
    guard try revision(url) == expected else { throw FilesError("stale_revision") }
  }
  private func metadata(_ url: URL) throws -> Value {
    let ref = try decode(reference(url))
    let v = try url.resourceValues(forKeys: [
      .isDirectoryKey, .isPackageKey, .fileSizeKey, .isUbiquitousItemKey,
      .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadingKey,
      .ubiquitousItemIsUploadedKey, .ubiquitousItemHasUnresolvedConflictsKey,
    ])
    var fields: [String: Value] = [
      "item_id": .string(try reference(url)), "root_id": .string(ref.root),
      "relative_path": .string(ref.path), "name": .string(url.lastPathComponent),
      "revision": .string(try revision(url)),
      "kind": .string(v.isPackage == true ? "package" : v.isDirectory == true ? "folder" : "file"),
      "size": .int(v.fileSize ?? 0), "cloud_sync_confirmed": .bool(false),
    ]
    let cloud = try fs.cloudStatus(url)
    if let x = cloud.ubiquitous { fields["is_ubiquitous"] = .bool(x) }
    if let x = cloud.downloading { fields["download_status"] = .string(x) }
    if let x = cloud.uploading { fields["is_uploading"] = .bool(x) }
    if let x = cloud.uploaded { fields["is_uploaded"] = .bool(x) }
    if let x = cloud.conflicts { fields["has_conflicts"] = .bool(x) }
    return .object(fields)
  }
  private func available(_ url: URL) throws -> Bool {
    try fs.cloudStatus(url).locallyAvailable
  }
  private func fileHash(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let bytes = try handle.read(upToCount: Self.chunkSize), !bytes.isEmpty {
      hash.update(data: bytes)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private func str(_ a: [String: Value], _ k: String) throws -> String {
    guard let value = a[k]?.stringValue, !value.isEmpty, value.utf8.count <= 1_048_576 else {
      throw FilesError("invalid_" + k)
    }
    return value
  }
  private func number(_ a: [String: Value], _ k: String, default value: Int? = nil) throws -> Int {
    guard let n = a[k]?.intValue ?? (a[k] == nil ? value : nil), n >= 0 else {
      throw FilesError("invalid_" + k)
    }
    return n
  }
  private func upload(_ a: [String: Value]) throws -> Upload {
    let id = try str(a, "upload_id")
    guard var upload = state!.uploads[id] else { throw FilesError("upload_unavailable") }
    if upload.status == "receiving", Date().timeIntervalSince(upload.created) > 86_400 {
      upload.status = "expired"
      state!.uploads[id] = upload
      try save()
      try? fm.removeItem(at: chunkURL(id))
    }
    return upload
  }
  private func status(_ upload: Upload) -> Value {
    .object([
      "upload_id": .string(upload.id), "status": .string(upload.status),
      "received": .int(Int(upload.received)), "size": .int(Int(upload.size)),
    ])
  }
  private func execute(_ name: String, _ a: [String: Value]) throws -> Value {
    guard let definition = ICloudToolCatalog.definitions.first(where: { "icloud_" + $0.0 == name }),
      Set(a.keys).isSubset(of: Set(definition.1)), definition.2.allSatisfy({ a[$0] != nil })
    else { throw FilesError("invalid_arguments") }
    try load()
    try validateRoots()
    let operation = definition.0
    let mutations = [
      "begin_upload", "upload_chunk", "commit_upload", "abort_upload", "create_folder", "copy_item",
      "move_item", "rename_item", "trash_item",
    ]
    if mutations.contains(operation) {
      try policy.requireMutation(trash: operation == "trash_item")
      let key = try str(a, "idempotency_key")
      guard key.utf8.count <= 200 else { throw FilesError("invalid_idempotency_key") }
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      let fingerprint = digest(
        try encoder.encode(
          Value.object(["operation": .string(operation), "arguments": .object(a)])))
      if let receipt = state!.receipts[key] {
        guard receipt.fingerprint == fingerprint else { throw FilesError("idempotency_key_reused") }
        guard let result = receipt.result else {
          throw FilesError("operation_indeterminate_inspect_before_retry")
        }
        return result
      }
      // Durable intent makes a crash after filesystem publication fail closed, never replays a mutation.
      state!.receipts[key] = .init(fingerprint: fingerprint)
      try save()
      mutationEffectStarted = false
      do {
        let result = try perform(operation, a)
        state!.receipts[key] = .init(fingerprint: fingerprint, result: result)
        try save()
        return result
      } catch {
        // Failed validation has no effect; retain intent for potentially partial filesystem failures.
        if !mutationEffectStarted {
          state!.receipts.removeValue(forKey: key)
          try save()
        }
        throw error
      }
    }
    return try perform(operation, a)
  }
  private func perform(_ op: String, _ a: [String: Value]) throws -> Value {
    if op == "list_roots" {
      return .array(
        try roots.map { root in
          .object([
            "id": .string(root.id), "name": .string(root.name),
            "item_id": .string(try token(.init(root: root.id, path: ""))),
          ])
        })
    }
    if op == "get_upload_status" { return status(try upload(a)) }
    if op == "begin_upload" {
      let parentID = try str(a, "parent_id")
      let name = try str(a, "name")
      let parent = try resolve(parentID)
      _ = try child(parent, name: name)
      let size = Int64(try number(a, "size"))
      let sha = try str(a, "sha256").lowercased()
      guard sha.count == 64, sha.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
        throw FilesError("invalid_sha256")
      }
      let reserved = state!.uploads.values.filter {
        $0.status == "receiving" || $0.status == "committing"
      }.reduce(Int64(0)) { $0 + $1.size }
      guard size <= policy.stagingQuota, reserved <= policy.stagingQuota - size else {
        throw FilesError("staging_quota_exceeded")
      }
      if let item = a["item_id"]?.stringValue {
        let target = try resolve(item, protectRoot: true)
        guard target.path == (try child(parent, name: name)).path else {
          throw FilesError("replacement_target_mismatch")
        }
        try check(target, str(a, "revision"))
        try ordinaryFile(target)
      } else {
        try noCollision(child(parent, name: name))
      }
      let id = UUID().uuidString
      let upload = Upload(
        id: id, parent: parentID, name: name, size: size, sha256: sha,
        item: a["item_id"]?.stringValue, revision: a["revision"]?.stringValue,
        created: Date(), received: 0, status: "receiving")
      mutationEffectStarted = true
      guard
        fm.createFile(
          atPath: chunkURL(id).path, contents: nil, attributes: [.posixPermissions: 0o600])
      else { throw FilesError("staging_unavailable") }
      state!.uploads[id] = upload
      try save()
      return status(upload)
    }
    if ["upload_chunk", "commit_upload", "abort_upload"].contains(op) {
      var upload = try upload(a)
      if op == "abort_upload" {
        guard upload.status != "committed", upload.status != "committing" else {
          throw FilesError("upload_not_abortable")
        }
        mutationEffectStarted = true
        upload.status = "aborted"
        state!.uploads[upload.id] = upload
        try save()
        try? fm.removeItem(at: chunkURL(upload.id))
        return status(upload)
      }
      guard upload.status == "receiving" else { throw FilesError("upload_not_receiving") }
      if op == "upload_chunk" {
        let offset = Int64(try number(a, "offset"))
        let encoded = try str(a, "data")
        guard encoded.utf8.count <= ((Self.chunkSize + 2) / 3) * 4,
          let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= Self.chunkSize,
          offset <= upload.received, Int64(bytes.count) <= upload.size - offset
        else { throw FilesError("invalid_chunk") }
        let handle = try FileHandle(forUpdating: chunkURL(upload.id))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        if offset < upload.received {
          guard offset + Int64(bytes.count) <= upload.received,
            try handle.read(upToCount: bytes.count) == bytes
          else { throw FilesError("chunk_retry_mismatch") }
        } else {
          mutationEffectStarted = true
          try handle.write(contentsOf: bytes)
          try handle.synchronize()
          upload.received += Int64(bytes.count)
          state!.uploads[upload.id] = upload
          try save()
        }
        return status(upload)
      }
      guard upload.received == upload.size else { throw FilesError("upload_incomplete") }
      guard try fileHash(chunkURL(upload.id)) == upload.sha256 else {
        throw FilesError("checksum_mismatch")
      }
      let parent = try resolve(upload.parent)
      return try fs.coordinated([parent], writing: true) {
        let currentParent = try resolve(upload.parent)
        let target = try child(currentParent, name: upload.name)
        if let item = upload.item {
          let existing = try resolve(item, protectRoot: true)
          guard existing.path == target.path else {
            throw FilesError("replacement_target_mismatch")
          }
          try check(existing, upload.revision!)
          try ordinaryFile(existing)
        } else {
          try noCollision(target)
        }
        try conflict(currentParent)
        mutationEffectStarted = true
        upload.status = "committing"
        state!.uploads[upload.id] = upload
        try save()
        // Sibling staging gives atomic publication even when private storage is on another volume.
        let sibling = currentParent.appendingPathComponent(
          ".apple-platform-upload-" + UUID().uuidString)
        defer { try? fm.removeItem(at: sibling) }
        try fm.copyItem(at: chunkURL(upload.id), to: sibling)
        if upload.item != nil {
          _ = try fm.replaceItemAt(target, withItemAt: sibling)
        } else {
          try fm.moveItem(at: sibling, to: target)
        }
        upload.status = "committed"
        state!.uploads[upload.id] = upload
        try save()
        try? fm.removeItem(at: chunkURL(upload.id))
        return try metadata(target)
      }
    }
    if op == "create_folder" {
      let parentID = try str(a, "parent_id")
      let parent = try resolve(parentID)
      return try fs.coordinated([parent], writing: true) {
        let parent = try resolve(parentID)
        try conflict(parent)
        let target = try child(parent, name: str(a, "name"))
        try noCollision(target)
        mutationEffectStarted = true
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        return try metadata(target)
      }
    }
    let itemID = try str(a, "item_id")
    let url = try resolve(itemID)
    // A normal ubiquitous-item read claim may wait for content downloads before
    // entering its accessor. Metadata tools must never acquire that kind of claim.
    if op == "read_file", try !available(url) {
      return try fs.coordinated([url], writing: false, metadataOnly: true) {
        let current = try resolve(itemID)
        try ordinaryFile(current)
        try check(current, str(a, "revision"))
        return .object(["status": .string("download_pending"), "retryable": .bool(true)])
      }
    }
    let writing = ["copy_item", "move_item", "rename_item", "trash_item"].contains(op)
    var coordinated = [url]
    if let parent = a["parent_id"]?.stringValue { coordinated.append(try resolve(parent)) }
    return try fs.coordinated(
      coordinated, writing: writing, metadataOnly: !writing && op != "read_file"
    ) {
      let url = try resolve(itemID, protectRoot: writing)
      switch op {
      case "get_item": return try metadata(url)
      case "list_items", "search_items":
        let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard v.isDirectory == true, v.isPackage != true else { throw FilesError("not_folder") }
        let rev = try revision(url)
        let limit = try number(a, "limit", default: 50)
        guard (1...200).contains(limit) else { throw FilesError("invalid_limit") }
        let query = op == "search_items" ? try str(a, "query") : ""
        let scope = digest(Data((itemID + "|" + query + "|" + rev).utf8))
        var offset = 0
        if let cursor = a["cursor"]?.stringValue {
          let ref = try decode(cursor)
          guard ref.root == scope, let parsed = Int(ref.path), parsed >= 0 else {
            throw FilesError("stale_cursor")
          }
          offset = parsed
        }
        let items = try
          (op == "search_items"
          ? descendants(url) : fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))
          .map(\.standardizedFileURL).filter {
            query.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(query)
          }.sorted { $0.path < $1.path }
        guard offset <= items.count else { throw FilesError("invalid_cursor") }
        let end = offset + min(limit, items.count - offset)
        var output: [String: Value] = [
          "items": .array(
            try items[offset..<end].map { item in
              _ = try resolve(reference(item))
              return try metadata(item)
            })
        ]
        if end < items.count {
          output["next_cursor"] = .string(try token(.init(root: scope, path: String(end))))
        }
        return .object(output)
      case "download_item":
        try ordinaryFile(url)
        if try !available(url) {
          try fs.requestDownload(url)
          return .object(["status": .string("download_pending"), "retryable": .bool(true)])
        }
        return try metadata(url)
      case "read_file":
        try ordinaryFile(url)
        try check(url, str(a, "revision"))
        if try !available(url) {
          return .object(["status": .string("download_pending"), "retryable": .bool(true)])
        }
        let offset = try number(a, "offset", default: 0)
        let length = try number(a, "length", default: Self.chunkSize)
        guard length > 0, length <= Self.chunkSize else { throw FilesError("invalid_length") }
        let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard offset <= size else { throw FilesError("invalid_offset") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let bytes = try handle.read(upToCount: length) ?? Data()
        try check(url, str(a, "revision"))
        let encoding = a["encoding"]?.stringValue ?? "base64"
        let content: String
        if encoding == "utf8" {
          guard let text = String(data: bytes, encoding: .utf8) else {
            throw FilesError("invalid_utf8_chunk_use_base64")
          }
          content = text
        } else if encoding == "base64" {
          content = bytes.base64EncodedString()
        } else {
          throw FilesError("invalid_encoding")
        }
        return .object([
          "data": .string(content), "encoding": .string(encoding), "offset": .int(offset),
          "next_offset": .int(offset + bytes.count), "eof": .bool(offset + bytes.count == size),
          "revision": .string(try revision(url)),
        ])
      case "copy_item", "move_item", "rename_item", "trash_item":
        try check(url, str(a, "revision"))
        if op == "trash_item" {
          mutationEffectStarted = true
          try fs.trash(url)
          return .object(["status": .string("trashed"), "cloud_sync_confirmed": .bool(false)])
        }
        let parent =
          op == "rename_item" ? url.deletingLastPathComponent() : try resolve(str(a, "parent_id"))
        let target = try child(parent, name: str(a, "name"))
        try noCollision(target)
        try conflict(parent)
        guard !contains(url.path, target.path) else {
          throw FilesError("destination_inside_source")
        }
        if op == "copy_item" {
          for item in [url] + (try descendants(url)) {
            if try !available(item) { throw FilesError("download_pending") }
          }
          mutationEffectStarted = true
          try fm.copyItem(at: url, to: target)
        } else {
          mutationEffectStarted = true
          try fm.moveItem(at: url, to: target)
        }
        return try metadata(target)
      default: throw FilesError("unknown_tool")
      }
    }
  }
  private func ordinaryFile(_ url: URL) throws {
    let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey])
    guard v.isRegularFile == true, v.isPackage != true else {
      throw FilesError("not_ordinary_file")
    }
  }
}
