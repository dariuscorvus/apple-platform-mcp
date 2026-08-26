import Foundation

/// A bounded, process-local idempotency store. It deliberately does not claim
/// cross-restart guarantees; callers must use a persistent store before making
/// that promise.
public actor ReminderIdempotencyStore {
  private struct Entry: Sendable {
    let fingerprint: String
    let result: Data
    let storedAt: Date
  }

  private struct InFlight: Sendable {
    let fingerprint: String
    let task: Task<Data, Error>
  }

  private let ttl: TimeInterval
  private let maxEntries: Int
  private var entries: [String: Entry] = [:]
  private var inFlight: [String: InFlight] = [:]

  public init(ttl: TimeInterval = 3_600, maxEntries: Int = 256) {
    self.ttl = max(1, ttl)
    self.maxEntries = max(1, maxEntries)
  }

  public func execute<Result: Codable & Sendable>(
    key: String,
    fingerprint: String,
    now: Date = Date(),
    operation: @escaping @Sendable () async throws -> Result
  ) async throws -> Result {
    try validate(key: key, fingerprint: fingerprint)
    pruneExpiredEntries(now: now)

    if let entry = entries[key] {
      guard entry.fingerprint == fingerprint else {
        throw ReminderError.idempotencyConflict
      }
      return try decode(entry.result, as: Result.self)
    }

    if let existing = inFlight[key] {
      guard existing.fingerprint == fingerprint else {
        throw ReminderError.idempotencyConflict
      }
      return try decode(try await existing.task.value, as: Result.self)
    }

    let task = Task<Data, Error> {
      let result = try await operation()
      return try JSONEncoder().encode(result)
    }
    inFlight[key] = InFlight(fingerprint: fingerprint, task: task)

    do {
      let result = try await task.value
      inFlight.removeValue(forKey: key)
      store(result, key: key, fingerprint: fingerprint, now: now)
      return try decode(result, as: Result.self)
    } catch {
      inFlight.removeValue(forKey: key)
      throw error
    }
  }

  private func validate(key: String, fingerprint: String) throws {
    guard !key.isEmpty, key == key.trimmingCharacters(in: .whitespacesAndNewlines) else {
      throw ReminderError.invalidInput("idempotency_key must be a non-empty trimmed string")
    }
    guard key.utf8.count <= 256 else {
      throw ReminderError.invalidInput("idempotency_key must be at most 256 bytes")
    }
    guard !fingerprint.isEmpty else {
      throw ReminderError.invalidInput("idempotency payload fingerprint is required")
    }
  }

  private func pruneExpiredEntries(now: Date) {
    entries = entries.filter { _, entry in
      now.timeIntervalSince(entry.storedAt) < ttl
    }
  }

  private func store(_ result: Data, key: String, fingerprint: String, now: Date) {
    entries[key] = Entry(fingerprint: fingerprint, result: result, storedAt: now)
    while entries.count > maxEntries,
      let oldest = entries.min(by: { lhs, rhs in
        if lhs.value.storedAt == rhs.value.storedAt {
          return lhs.key < rhs.key
        }
        return lhs.value.storedAt < rhs.value.storedAt
      })
    {
      entries.removeValue(forKey: oldest.key)
    }
  }

  private func decode<Result: Decodable>(_ result: Data, as type: Result.Type) throws -> Result {
    do {
      return try JSONDecoder().decode(Result.self, from: result)
    } catch {
      throw ReminderError.unknown
    }
  }
}

public enum ReminderMutationFingerprint {
  public static func make<Payload: Encodable>(
    operation: String,
    payload: Payload
  ) throws -> String {
    guard !operation.isEmpty else {
      throw ReminderError.invalidInput("idempotency operation is required")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    return operation + ":" + data.base64EncodedString()
  }
}
