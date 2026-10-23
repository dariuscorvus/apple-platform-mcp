import CoreServices
import Foundation
import ScriptingBridge

#if canImport(MailScriptingBridge)
  import MailScriptingBridge
#endif

public struct NotesError: Error, LocalizedError, Sendable {
  public let code: String
  public init(_ code: String) { self.code = code }
  public var errorDescription: String? {
    switch code {
    case "notesPolicyDenied": return "Notes creation is disabled by policy."
    case "notesPermissionRequired":
      return
        "Open Notes, then run apple-platform-mcp doctor --request-notes from the signed app bundle."
    case "notesNotRunning":
      return "Open Notes before using Notes tools or requesting Automation permission."
    case "notesPermissionDenied":
      return
        "Allow Apple Platform MCP to control Notes in System Settings > Privacy & Security > Automation."
    case "notesLocked": return "Password-protected notes cannot be read."
    case "notesSharedFolder": return "Creating notes in shared folders is not supported."
    case "notesNotFound":
      return "The selected Notes object no longer exists. Refresh its references."
    case "invalidReference": return "Use the exact Notes reference returned by a discovery tool."
    case "invalidInput": return "Notes arguments have an invalid type, size, or value."
    case "idempotencyConflict": return "This key belongs to a different Notes create request."
    case "notesJournalFull":
      return
        "The process-local Notes create journal is full. Verify previous outcomes before restarting."
    case "notesCreationOutcomeUnknown":
      return
        "Creation may have completed. Inspect the selected folder before any new create attempt."
    case "notesTraversalLimit": return "Notes folder traversal exceeded the safety limit."
    default: return "Notes automation failed. Check Notes availability and Automation permission."
    }
  }
}

public struct NotesContainer: Codable, Sendable, Equatable {
  public let id: String
  public let name: String
  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}
public struct NotesItem: Codable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let locked: Bool
  public let text: String?
  public let truncated: Bool
  public init(
    id: String, name: String, locked: Bool = false, text: String? = nil, truncated: Bool = false
  ) {
    self.id = id
    self.name = name
    self.locked = locked
    self.text = text
    self.truncated = truncated
  }
}
public struct NotesPage: Codable, Sendable {
  public let items: [NotesItem]
  public let truncated: Bool
}

/// Backend accepts raw Apple identifiers; only the service issues public references.
public protocol NotesRepository: Sendable {
  func accounts() async throws -> [NotesContainer]
  func folders(account: String) async throws -> [NotesContainer]
  func search(account: String, folder: String, query: String, limit: Int) async throws -> NotesPage
  func get(account: String, folder: String, note: String) async throws -> NotesItem
  func create(account: String, folder: String, html: String) async throws -> NotesItem
}

/// The envelope records the full containment chain and rejects other tool namespaces.
/// References identify objects; they do not grant access or act as credentials.
enum NotesReference {
  struct Payload: Codable {
    let version: Int
    let kind: String
    let ids: [String]
  }
  static func make(_ kind: String, _ ids: [String]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return "notes_v1_"
      + (try encoder.encode(Payload(version: 1, kind: kind, ids: ids))).base64EncodedString()
  }
  static func decode(_ reference: String, kind: String, count: Int) throws -> [String] {
    guard reference.hasPrefix("notes_v1_"), reference.utf8.count <= 16_384,
      let data = Data(base64Encoded: String(reference.dropFirst(9))),
      let payload = try? JSONDecoder().decode(Payload.self, from: data),
      payload.version == 1, payload.kind == kind, payload.ids.count == count,
      payload.ids.allSatisfy({ !$0.isEmpty })
    else { throw NotesError("invalidReference") }
    return payload.ids
  }
}

public actor NotesToolService {
  private let repository: any NotesRepository
  public nonisolated let mutationMode: ReminderMutationMode
  private let maxResults: Int
  private let maxBodyBytes: Int
  private struct Attempt {
    let payload: [String]
    let task: Task<NotesItem, Error>
  }
  // Entries, including ambiguous failures, are never evicted during this process.
  private var attempts: [String: Attempt] = [:]
  public init(
    repository: any NotesRepository, mutationMode: ReminderMutationMode = .denied,
    maxResults: Int = 50, maxBodyBytes: Int = 262_144
  ) {
    self.repository = repository
    self.mutationMode = mutationMode
    self.maxResults = min(1000, max(1, maxResults))
    self.maxBodyBytes = max(1, maxBodyBytes)
  }
  public func accounts() async throws -> [NotesContainer] {
    try await repository.accounts().map {
      NotesContainer(id: try NotesReference.make("account", [$0.id]), name: $0.name)
    }
  }
  public func folders(accountID: String) async throws -> [NotesContainer] {
    let ids = try NotesReference.decode(accountID, kind: "account", count: 1)
    return try await repository.folders(account: ids[0]).map {
      NotesContainer(id: try NotesReference.make("folder", [ids[0], $0.id]), name: $0.name)
    }
  }
  public func search(folderID: String, query: String = "", limit: Int? = nil) async throws
    -> NotesPage
  {
    let ids = try NotesReference.decode(folderID, kind: "folder", count: 2)
    guard query.utf8.count <= 4096, limit == nil || limit! > 0 else {
      throw NotesError("invalidInput")
    }
    let page = try await repository.search(
      account: ids[0], folder: ids[1], query: query,
      limit: min(limit ?? maxResults, maxResults))
    return NotesPage(
      items: try page.items.map { try publicItem($0, parent: ids) }, truncated: page.truncated)
  }
  public func get(noteID: String) async throws -> NotesItem {
    let ids = try NotesReference.decode(noteID, kind: "note", count: 3)
    let item = try await repository.get(account: ids[0], folder: ids[1], note: ids[2])
    guard !item.locked else { throw NotesError("notesLocked") }
    return try publicItem(item, parent: Array(ids.prefix(2)))
  }
  public func create(folderID: String, title: String, text: String, key: String) async throws
    -> NotesItem
  {
    guard mutationMode == .allowed else { throw NotesError("notesPolicyDenied") }
    let ids = try NotesReference.decode(folderID, kind: "folder", count: 2)
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !title.contains("\n"), !title.contains("\r"), title.utf8.count <= 10_000,
      title.utf8.count + text.utf8.count <= maxBodyBytes,
      !key.isEmpty, key == key.trimmingCharacters(in: .whitespacesAndNewlines),
      key.utf8.count <= 256
    else { throw NotesError("invalidInput") }
    let payload = [folderID, title, text]
    if let previous = attempts[key] {
      guard previous.payload == payload else { throw NotesError("idempotencyConflict") }
      return try await previous.task.value
    }
    guard attempts.count < 256 else { throw NotesError("notesJournalFull") }
    let html = Self.html(title: title, text: text)
    let repository = self.repository
    let task = Task<NotesItem, Error> {
      do {
        let item = try await repository.create(account: ids[0], folder: ids[1], html: html)
        guard !item.id.isEmpty else { throw NotesError("notesCreationOutcomeUnknown") }
        return try self.publicItem(item, parent: ids)
      } catch {
        // Once dispatched, do not assume failure means no write occurred.
        throw NotesError("notesCreationOutcomeUnknown")
      }
    }
    attempts[key] = Attempt(payload: payload, task: task)
    return try await task.value
  }
  private func publicItem(_ item: NotesItem, parent: [String]) throws -> NotesItem {
    let bytes = item.text.map { Array($0.utf8) }
    var text = item.text
    let truncated = item.truncated || (bytes?.count ?? 0) > maxBodyBytes
    if let bytes, bytes.count > maxBodyBytes {
      var prefix = Array(bytes.prefix(maxBodyBytes))
      while String(bytes: prefix, encoding: .utf8) == nil { prefix.removeLast() }
      text = String(bytes: prefix, encoding: .utf8)
    }
    return NotesItem(
      id: try NotesReference.make("note", parent + [item.id]), name: item.name,
      locked: item.locked, text: text, truncated: truncated)
  }
  static func html(title: String, text: String) -> String {
    func escape(_ value: String) -> String {
      value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
        .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        .replacingOccurrences(of: "\n", with: "<br>")
    }
    return "<div><b>\(escape(title))</b></div><div>\(escape(text))</div>"
  }
}

/// All ScriptingBridge objects stay inside one actor. No user-provided code executes.
public actor ScriptingBridgeNotesRepository: NotesRepository {
  public init() {}
  private func execute(_ request: [String: Any]) throws -> [String: Any] {
    try NotesAutomation.requirePermission()
    var error: NSError?
    let result = APSNotesExecute(request, &error)
    if let error {
      let code = error.userInfo["notesCode"] as? String ?? "notesAutomationFailed"
      let known = [
        "notesPermissionDenied", "notesLocked", "notesSharedFolder", "notesNotFound",
        "notesTraversalLimit", "ambiguousReference",
      ]
      throw NotesError(known.contains(code) ? code : "notesAutomationFailed")
    }
    guard let result = result as? [String: Any] else { throw NotesError("notesAutomationFailed") }
    return result
  }
  private func containers(_ result: [String: Any]) throws -> [NotesContainer] {
    guard let items = result["items"] as? [[String: Any]] else {
      throw NotesError("notesAutomationFailed")
    }
    return try items.map {
      guard let id = $0["id"] as? String, !id.isEmpty, let name = $0["name"] as? String
      else { throw NotesError("notesAutomationFailed") }
      return NotesContainer(id: id, name: name)
    }
  }
  private func item(_ value: [String: Any]) throws -> NotesItem {
    guard let id = value["id"] as? String, !id.isEmpty, let name = value["name"] as? String,
      let locked = value["locked"] as? Bool
    else { throw NotesError("notesAutomationFailed") }
    return NotesItem(id: id, name: name, locked: locked, text: value["text"] as? String)
  }
  public func accounts() async throws -> [NotesContainer] {
    try containers(execute(["operation": "accounts"]))
  }
  public func folders(account: String) async throws -> [NotesContainer] {
    try containers(execute(["operation": "folders", "account": account]))
  }
  public func search(account: String, folder: String, query: String, limit: Int) async throws
    -> NotesPage
  {
    let result = try execute([
      "operation": "search", "account": account, "folder": folder, "query": query, "limit": limit,
    ])
    guard let values = result["items"] as? [[String: Any]],
      let truncated = result["truncated"] as? Bool
    else {
      throw NotesError("notesAutomationFailed")
    }
    return NotesPage(items: try values.map(item), truncated: truncated)
  }
  public func get(account: String, folder: String, note: String) async throws -> NotesItem {
    try item(execute(["operation": "get", "account": account, "folder": folder, "note": note]))
  }
  public func create(account: String, folder: String, html: String) async throws -> NotesItem {
    try item(execute(["operation": "create", "account": account, "folder": folder, "html": html]))
  }
}

/// Setup is the only prompt-capable path. MCP operations only inspect permission.
public enum NotesAutomation {
  public static func permission(request: Bool = false) -> String {
    guard let app = SBApplication(bundleIdentifier: "com.apple.Notes"), app.isRunning else {
      return "notesNotRunning"
    }
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Notes")
    guard let address = target.aeDesc else { return "notesUnavailable" }
    let status = AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, request)
    switch status {
    case OSStatus(noErr): return "allowed"
    case OSStatus(errAEEventWouldRequireUserConsent): return "notesPermissionRequired"
    case OSStatus(errAEEventNotPermitted): return "notesPermissionDenied"
    default: return "notesUnavailable"
    }
  }
  static func requirePermission() throws {
    let status = permission()
    guard status == "allowed" else { throw NotesError(status) }
  }
}
