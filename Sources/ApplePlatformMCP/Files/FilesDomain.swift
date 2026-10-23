import Foundation
import MCP

public struct ICloudRoot: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let path: String
  public init(id: String, name: String, path: String) {
    self.id = id
    self.name = name
    self.path = path
  }
}

public enum ICloudMutationMode: String, Codable, Sendable { case denied, allowed }
public struct FilesPolicy: Sendable {
  public let mutationMode: ICloudMutationMode
  public let trashEnabled: Bool
  public let stagingQuota: Int64
  public init(
    mutationMode: ICloudMutationMode = .denied, trashEnabled: Bool = false,
    stagingQuota: Int64 = 1_073_741_824
  ) {
    self.mutationMode = mutationMode
    self.trashEnabled = trashEnabled
    self.stagingQuota = max(0, stagingQuota)
  }
  func requireMutation(trash: Bool = false) throws {
    guard mutationMode == .allowed, !trash || trashEnabled else {
      throw FilesError("policy_denied")
    }
  }
}
public struct FilesError: Error, LocalizedError, Sendable {
  public let code: String
  public init(_ code: String) { self.code = code }
  public var recovery: String? {
    switch code {
    case "download_pending": return "Retry after macOS finishes downloading."
    case "staging_busy_retry":
      return "Retry this exact request with the same key after the other Files request finishes."
    case "stale_revision", "stale_cursor":
      return "Discover the item again and use its current revision or restart pagination."
    case "operation_indeterminate_inspect_before_retry":
      return
        "Inspect the destination and upload status before retrying; the previous mutation may have completed."
    default: return nil
    }
  }
  public var errorDescription: String? { "iCloud Files: \(code)" }
}

public enum ICloudToolCatalog {
  public static let definitions: [(String, [String], [String])] = [
    ("list_roots", [], []),
    ("list_items", ["item_id", "cursor", "limit"], ["item_id"]),
    ("search_items", ["item_id", "query", "cursor", "limit"], ["item_id", "query"]),
    ("get_item", ["item_id"], ["item_id"]),
    ("download_item", ["item_id"], ["item_id"]),
    (
      "read_file", ["item_id", "revision", "offset", "length", "encoding"], ["item_id", "revision"]
    ),
    (
      "begin_upload",
      ["parent_id", "name", "size", "sha256", "item_id", "revision", "idempotency_key"],
      ["parent_id", "name", "size", "sha256", "idempotency_key"]
    ),
    (
      "upload_chunk", ["upload_id", "offset", "data", "idempotency_key"],
      ["upload_id", "offset", "data", "idempotency_key"]
    ),
    ("get_upload_status", ["upload_id"], ["upload_id"]),
    ("commit_upload", ["upload_id", "idempotency_key"], ["upload_id", "idempotency_key"]),
    ("abort_upload", ["upload_id", "idempotency_key"], ["upload_id", "idempotency_key"]),
    (
      "create_folder", ["parent_id", "name", "idempotency_key"],
      ["parent_id", "name", "idempotency_key"]
    ),
    (
      "copy_item", ["item_id", "revision", "parent_id", "name", "idempotency_key"],
      ["item_id", "revision", "parent_id", "name", "idempotency_key"]
    ),
    (
      "move_item", ["item_id", "revision", "parent_id", "name", "idempotency_key"],
      ["item_id", "revision", "parent_id", "name", "idempotency_key"]
    ),
    (
      "rename_item", ["item_id", "revision", "name", "idempotency_key"],
      ["item_id", "revision", "name", "idempotency_key"]
    ),
    (
      "trash_item", ["item_id", "revision", "idempotency_key"],
      ["item_id", "revision", "idempotency_key"]
    ),
  ]
  public static let tools: [Tool] = definitions.map { name, fields, required in
    let descriptions: [String: String] = [
      "item_id": "Opaque item reference from discovery; source or replacement item.",
      "parent_id": "Opaque destination folder reference from discovery.",
      "revision":
        "Exact current revision from get_item; required for existing-item changes and reads.",
      "name": "Single destination name; no path components or separators.",
      "size": "Expected complete upload size in decoded bytes, including zero for empty files.",
      "sha256": "64 hexadecimal characters: SHA-256 of the complete decoded file.",
      "upload_id": "Upload identifier returned by begin_upload.",
      "offset": "Decoded byte offset; upload chunks must be sequential or an identical retry.",
      "length": "Maximum decoded read bytes, from 1 to 262144.",
      "data": "Base64 chunk, at most 262144 decoded bytes.",
      "encoding": "base64 (default) or utf8; UTF-8 chunks must end on character boundaries.",
      "limit": "Page size from 1 to 200; default 50.",
      "cursor": "Opaque next_cursor from the same folder/query; restart if stale.",
      "query": "Nonempty case-insensitive filename substring; never searches contents.",
      "idempotency_key":
        "Durable retry key, at most 200 UTF-8 bytes; reuse only for this exact request.",
    ]
    let integers: Set<String> = ["size", "offset", "length", "limit"]
    let readOnly = [
      "list_roots", "list_items", "search_items", "get_item", "read_file", "get_upload_status",
    ].contains(name)
    return Tool(
      name: "icloud_" + name,
      description:
        "Configured iCloud folders: \(name). References and revisions come from discovery. Chunks are at most 262144 decoded bytes. Local success does not confirm cloud sync.",
      inputSchema: .object([
        "type": .string("object"), "additionalProperties": .bool(false),
        "properties": .object(
          Dictionary(
            uniqueKeysWithValues: fields.map {
              (
                $0,
                Value.object([
                  "type": .string(integers.contains($0) ? "integer" : "string"),
                  "description": .string(descriptions[$0] ?? ""),
                ])
              )
            })),
        "required": .array(required.map(Value.string)),
      ]),
      annotations: .init(readOnlyHint: readOnly, destructiveHint: !readOnly, openWorldHint: true))
  }
}
