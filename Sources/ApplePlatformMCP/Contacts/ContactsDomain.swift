import Foundation

public enum ContactsAccess: String, Codable, Sendable {
  case notDetermined = "not_determined"
  case restricted, denied, authorized, limited, unavailable
  public static func normalized(_ raw: Int) -> Self {
    switch raw {
    case 0: .notDetermined
    case 1: .restricted
    case 2: .denied
    case 3: .authorized
    case 4: .limited
    default: .unavailable
    }
  }
  public var readable: Bool { self == .authorized || self == .limited }
}
public struct ContactsError: Error, LocalizedError, Sendable, Equatable {
  public let code: String
  public init(_ code: String) { self.code = code }
  public var errorDescription: String? {
    switch code {
    case "contactsPermissionRequired":
      "Run doctor --request-contacts from the actual signed app host."
    case "contactsPermissionDenied":
      "Contacts access is denied or restricted. Check macOS Contacts privacy settings."
    case "contactsInvalidReference":
      "Use the exact versioned contact or container reference returned by discovery."
    case "contactsNotFound":
      "The exact contact/container is no longer visible. Refresh discovery; no name fallback."
    case "contactsAmbiguousReference":
      "The reference resolved to multiple records; refresh discovery."
    case "contactsInvalidInput":
      "Contacts arguments have an invalid type, field, reference or size."
    default: "Contacts operation failed without exposing backend details."
    }
  }
}
struct ContactsAnchor: Codable, Equatable, Sendable {
  let version: Int
  let kind: String
  let container: String
  let record: String?
}
enum ContactsReferenceCodec {
  static func encode(container: String, record: String? = nil) throws -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return "contacts_v1_"
      + (try e.encode(
        ContactsAnchor(
          version: 1,
          kind: record == nil ? "container" : "record", container: container, record: record)))
      .base64EncodedString()
  }
  static func decode(_ value: String, record: Bool) throws -> ContactsAnchor {
    guard value.utf8.count <= 8192, value.hasPrefix("contacts_v1_"),
      let d = Data(base64Encoded: String(value.dropFirst(12))),
      let a = try? JSONDecoder().decode(ContactsAnchor.self, from: d), a.version == 1,
      a.kind == (record ? "record" : "container"), !a.container.isEmpty,
      a.container.utf8.count <= 2048,
      record
        ? (a.record?.isEmpty == false && (a.record?.utf8.count ?? 0) <= 2048) : a.record == nil,
      try encode(container: a.container, record: a.record) == value
    else { throw ContactsError("contactsInvalidReference") }
    return a
  }
}
public struct ContactsContainer: Codable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let provider_type: String
}
public struct ContactsChannel: Codable, Sendable, Equatable {
  public let label: String
  public let value: String
}
public struct ContactsSummary: Codable, Sendable, Equatable {
  public let id: String
  public let container_id: String
  public let kind: String
  public let given_name: String
  public let family_name: String
  public let organization: String
  public let truncated: Bool
}
public struct ContactsRecord: Codable, Sendable, Equatable {
  public let summary: ContactsSummary
  public let middle_name: String
  public let name_prefix: String
  public let name_suffix: String
  public let emails: [ContactsChannel]
  public let phones: [ContactsChannel]
  public let truncated: Bool
}
public struct ContactsPage<Item: Codable & Sendable>: Codable, Sendable {
  public let items: [Item]
  public let authorization: ContactsAccess
  public let visibility: String
  public let truncated: Bool
  public let scan_complete: Bool
  public let records_examined: Int
  public let limit: Int
  public var record_semantics: String = "individual_container_records_not_unified"
}
public enum ContactsField: String, Codable, Sendable, CaseIterable {
  case name, company, email, phone
}
public struct ContactsQuery: Sendable {
  public let query: String
  public let fields: [ContactsField]
  public let containerIDs: [String]?
  public let limit: Int
  public static func fold(_ s: String) -> String {
    s.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }
  public static func digits(_ s: String) -> String {
    String(s.filter { $0.isASCII && $0.isNumber })
  }
  func matches(names: [String], company: String, emails: [String], phones: [String]) -> Bool {
    let q = Self.fold(query)
    return fields.contains { field in
      switch field {
      case .name:
        return names.contains { Self.fold($0).contains(q) }
          || Self.fold(names.filter { !$0.isEmpty }.joined(separator: " ")).contains(q)
      case .company: return Self.fold(company).contains(q)
      case .email: return emails.contains { Self.fold($0).contains(q) }
      case .phone:
        let digits = Self.digits(query)
        return !digits.isEmpty && phones.contains { Self.digits($0).contains(digits) }
      }
    }
  }
}
public protocol ContactsRepository: Sendable {
  func authorizationStatus() async -> ContactsAccess
  func listContainers(maximum: Int) async throws -> ContactsPage<ContactsContainer>
  func search(_ query: ContactsQuery, maximumScan: Int) async throws -> ContactsPage<
    ContactsSummary
  >
  func get(id: String) async throws -> ContactsRecord
}
public struct ContactsReadResult: Codable, Sendable {
  public let contact: ContactsRecord
  public let authorization: ContactsAccess
  public let visibility: String
}
public struct ContactsToolService: Sendable {
  let repository: any ContactsRepository
  let maximum: Int
  public init(repository: any ContactsRepository, maxResults: Int = 100) {
    self.repository = repository
    maximum = min(1000, max(1, maxResults))
  }
  public func authorizationStatus() async -> ContactsAccess {
    await repository.authorizationStatus()
  }
  func requireRead() async throws {
    let a = await authorizationStatus()
    guard a.readable else {
      throw ContactsError(
        a == .notDetermined ? "contactsPermissionRequired" : "contactsPermissionDenied")
    }
  }
  func list() async throws -> ContactsPage<ContactsContainer> {
    try await requireRead()
    return try await repository.listContainers(maximum: maximum)
  }
  func search(query: String, fields: [ContactsField], ids: [String]?, limit: Int?) async throws
    -> ContactsPage<ContactsSummary>
  {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard q.count >= 2, q.utf8.count <= 256,
      !q.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !fields.isEmpty, Set(fields).count == fields.count, fields.count <= 4,
      limit == nil || (limit! >= 1 && limit! <= 1000)
    else { throw ContactsError("contactsInvalidInput") }
    if let ids {
      guard !ids.isEmpty, ids.count <= 100, Set(ids).count == ids.count else {
        throw ContactsError("contactsInvalidInput")
      }
      for id in ids { _ = try ContactsReferenceCodec.decode(id, record: false) }
    }
    if fields == [.phone], ContactsQuery.digits(q).count < 2 {
      throw ContactsError("contactsInvalidInput")
    }
    try await requireRead()
    return try await repository.search(
      .init(
        query: q, fields: fields, containerIDs: ids,
        limit: min(limit ?? maximum, maximum)), maximumScan: 1000)
  }
  func get(id: String) async throws -> ContactsReadResult {
    _ = try ContactsReferenceCodec.decode(id, record: true)
    try await requireRead()
    let c = try await repository.get(id: id)
    let a = await authorizationStatus()
    guard a.readable else { throw ContactsError("contactsPermissionDenied") }
    return .init(
      contact: c, authorization: a,
      visibility: "authorized_visible_subset_no_account_completeness_claim")
  }
}
