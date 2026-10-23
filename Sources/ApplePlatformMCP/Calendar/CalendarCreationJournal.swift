import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Durable reservation precedes EventKit. Pending records never authorize another write.
public actor CalendarCreationJournal {
  public static var defaultURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".local/state/apple-platform-mcp/calendar-idempotency.sqlite3")
  }
  enum Reservation: Sendable {
    case reserved
    case cached(CalendarCreationResult)
  }
  private let url: URL
  public init(url: URL = CalendarCreationJournal.defaultURL) { self.url = url }
  static func hash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static func fingerprint(_ request: CalendarCreateRequest) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return hash(
      "calendar_create_event:" + String(decoding: try encoder.encode(request), as: UTF8.self))
  }
  private struct Row {
    let fingerprint: String
    let state: String
    let result: String?
  }
  func reserve(key: String, fingerprint: String) throws -> Reservation {
    try database { db in
      try execute(db, "BEGIN IMMEDIATE")
      var committed = false
      defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
      let reservation: Reservation
      if let row = try row(db, key: Self.hash(key)) {
        guard row.fingerprint == fingerprint else {
          throw CalendarError("calendarIdempotencyConflict")
        }
        guard row.state == "succeeded" else {
          throw CalendarError("calendarCreationOutcomeUnknown")
        }
        reservation = .cached(try decodeResult(row.result))
      } else {
        let statement = try prepare(
          db,
          "INSERT INTO calendar_creations(key_hash,fingerprint,state,created_at) VALUES(?,?,'pending',?)"
        )
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, Self.hash(key))
        try bind(statement, 2, fingerprint)
        try bind(statement, 3, CalendarTimeRange.timestamp(Date()))
        guard sqlite3_step(statement) == SQLITE_DONE else {
          throw CalendarError("calendarJournalUnavailable")
        }
        reservation = .reserved
      }
      try execute(db, "COMMIT")
      committed = true
      return reservation
    }
  }
  func finish(key: String, fingerprint: String, result: CalendarCreationResult) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = String(decoding: try encoder.encode(result), as: UTF8.self)
    try database { db in
      let statement = try prepare(
        db,
        "UPDATE calendar_creations SET state='succeeded',result=?,finished_at=? WHERE key_hash=? AND fingerprint=? AND state='pending'"
      )
      defer { sqlite3_finalize(statement) }
      try bind(statement, 1, encoded)
      try bind(statement, 2, CalendarTimeRange.timestamp(Date()))
      try bind(statement, 3, Self.hash(key))
      try bind(statement, 4, fingerprint)
      guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
        throw CalendarError("calendarJournalUnavailable")
      }
    }
  }
  public func outcome(key: String) throws -> CalendarCreationOutcome {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return .init(status: "not_found", result: nil)
    }
    return try database { db in
      guard let value = try row(db, key: Self.hash(key)) else {
        return .init(status: "not_found", result: nil)
      }
      if value.state == "succeeded" {
        return .init(status: "succeeded", result: try decodeResult(value.result))
      }
      guard value.state == "pending" else { throw CalendarError("calendarJournalUnavailable") }
      return .init(status: "outcome_unknown", result: nil)
    }
  }
  private func decodeResult(_ string: String?) throws -> CalendarCreationResult {
    guard let string,
      let result = try? JSONDecoder().decode(CalendarCreationResult.self, from: Data(string.utf8))
    else {
      throw CalendarError("calendarJournalUnavailable")
    }
    return result
  }
  private func database<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    do {
      let newlyCreated = try secureStorage()
      var connection: OpaquePointer?
      // Foundation can preserve the /var alias even after resolvingSymlinksInPath.
      // SQLite NOFOLLOW requires POSIX realpath for the trusted parent directory.
      guard let parentPath = realpath(url.deletingLastPathComponent().path, nil) else {
        throw CalendarError("calendarJournalUnavailable")
      }
      let connectionPath = String(cString: parentPath) + "/" + url.lastPathComponent
      free(parentPath)
      let status = sqlite3_open_v2(
        connectionPath, &connection,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
      guard let db = connection else { throw CalendarError("calendarJournalUnavailable") }
      defer { sqlite3_close(db) }
      guard status == SQLITE_OK, sqlite3_busy_timeout(db, 5000) == SQLITE_OK else {
        throw CalendarError("calendarJournalUnavailable")
      }
      try execute(db, "PRAGMA journal_mode=DELETE")
      try execute(db, "PRAGMA synchronous=FULL")
      let versionQuery = try prepare(db, "PRAGMA user_version")
      guard sqlite3_step(versionQuery) == SQLITE_ROW else {
        throw CalendarError("calendarJournalUnavailable")
      }
      let version = sqlite3_column_int(versionQuery, 0)
      sqlite3_finalize(versionQuery)
      guard version == 1 || (version == 0 && newlyCreated) else {
        throw CalendarError("calendarJournalUnavailable")
      }
      try execute(
        db,
        "CREATE TABLE IF NOT EXISTS calendar_creations(key_hash TEXT PRIMARY KEY NOT NULL,fingerprint TEXT NOT NULL,state TEXT NOT NULL CHECK(state IN ('pending','succeeded')),result TEXT,created_at TEXT NOT NULL,finished_at TEXT)"
      )
      if version == 0 { try execute(db, "PRAGMA user_version=1") }
      return try body(db)
    } catch let error as CalendarError { throw error } catch {
      throw CalendarError("calendarJournalUnavailable")
    }
  }
  private func secureStorage() throws -> Bool {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw CalendarError("calendarJournalUnavailable")
    }
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var metadata = stat()
    guard lstat(parent.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0
    else { throw CalendarError("calendarJournalUnavailable") }
    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    if fd >= 0 {
      Darwin.close(fd)
    } else if errno != EEXIST {
      throw CalendarError("calendarJournalUnavailable")
    }
    guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0
    else { throw CalendarError("calendarJournalUnavailable") }
    return fd >= 0
  }
  private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw CalendarError("calendarJournalUnavailable")
    }
    return statement
  }
  private func execute(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw CalendarError("calendarJournalUnavailable")
    }
  }
  private func bind(_ statement: OpaquePointer, _ position: Int32, _ value: String) throws {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    guard sqlite3_bind_text(statement, position, value, -1, transient) == SQLITE_OK else {
      throw CalendarError("calendarJournalUnavailable")
    }
  }
  private func row(_ db: OpaquePointer, key: String) throws -> Row? {
    let statement = try prepare(
      db, "SELECT fingerprint,state,result FROM calendar_creations WHERE key_hash=?")
    defer { sqlite3_finalize(statement) }
    try bind(statement, 1, key)
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW, let fingerprint = sqlite3_column_text(statement, 0),
      let state = sqlite3_column_text(statement, 1)
    else { throw CalendarError("calendarJournalUnavailable") }
    return Row(
      fingerprint: String(cString: fingerprint), state: String(cString: state),
      result: sqlite3_column_text(statement, 2).map { String(cString: $0) })
  }
}
