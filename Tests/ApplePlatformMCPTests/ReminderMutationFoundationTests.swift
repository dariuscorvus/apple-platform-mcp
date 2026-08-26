import Foundation
import Testing

#if !XCODE_COMBINED_TEST_TARGET
  @testable import ApplePlatformMCPKit
#endif

@Suite("Reminder mutation policy")
struct ReminderMutationPolicyTests {
  @Test("defaults Reminder writes to denied independently of Mail mutation policy")
  func defaultsToDeniedIndependently() {
    let configuration = MailServerConfiguration(mutationMode: .allowed)

    #expect(ReminderPolicy().mutationMode == .denied)
    #expect(configuration.reminderPolicy.mutationMode == .denied)
    #expect(configuration.policy.mutationMode == .allowed)
    #expect(throws: ReminderError.self) {
      try ReminderPolicy().validateMutation()
    }
  }

  @Test("keeps confirmation-required Reminder writes fail-closed")
  func confirmationRequiredFailsClosed() {
    let policy = ReminderPolicy(mutationMode: .confirmationRequired)

    #expect(throws: ReminderError.self) {
      try policy.validateMutation()
    }
  }

  @Test("requires a separate gate before deleting a Reminder list")
  func listDeletionRequiresBothGates() throws {
    #expect(throws: ReminderError.self) {
      try ReminderPolicy(mutationMode: .allowed).validateListDeletion()
    }
    #expect(throws: ReminderError.self) {
      try ReminderPolicy(
        mutationMode: .confirmationRequired,
        listDeleteEnabled: true
      ).validateListDeletion()
    }

    try ReminderPolicy(
      mutationMode: .allowed,
      listDeleteEnabled: true
    ).validateListDeletion()
  }

  @Test("decodes Reminder write settings without changing Mail settings")
  func decodesIndependentConfiguration() throws {
    let data = Data(
      """
      {
        "mutation_mode": "denied",
        "reminder_mutation_mode": "allowed",
        "reminder_list_delete_enabled": true
      }
      """.utf8
    )

    let configuration = try JSONDecoder().decode(MailServerConfiguration.self, from: data)

    #expect(configuration.policy.mutationMode == .denied)
    #expect(configuration.reminderPolicy.mutationMode == .allowed)
    #expect(configuration.reminderPolicy.listDeleteEnabled == true)
  }
}

@Suite("Reminder idempotency store")
struct ReminderIdempotencyStoreTests {
  @Test("returns the original result for the same key and normalized payload")
  func returnsOriginalResult() async throws {
    let store = ReminderIdempotencyStore(ttl: 60, maxEntries: 2)
    let calls = InvocationCounter()
    let now = Date(timeIntervalSince1970: 1_000)

    let first = try await store.execute(
      key: "create-reminder-1",
      fingerprint: "reminder_create:payload-a",
      now: now
    ) {
      "value-\(await calls.increment())"
    }
    let retry = try await store.execute(
      key: "create-reminder-1",
      fingerprint: "reminder_create:payload-a",
      now: now.addingTimeInterval(1)
    ) {
      "value-\(await calls.increment())"
    }

    #expect(first == "value-1")
    #expect(retry == "value-1")
    #expect(await calls.value == 1)
  }

  @Test("rejects a reused key whose normalized payload differs")
  func rejectsPayloadConflict() async throws {
    let store = ReminderIdempotencyStore()

    _ = try await store.execute(
      key: "create-reminder-1",
      fingerprint: "reminder_create:payload-a"
    ) { "first" }

    await #expect(throws: ReminderError.self) {
      try await store.execute(
        key: "create-reminder-1",
        fingerprint: "reminder_create:payload-b"
      ) { "second" }
    }
  }

  @Test("expires process-local entries after their configured TTL")
  func expiresEntries() async throws {
    let store = ReminderIdempotencyStore(ttl: 60, maxEntries: 2)
    let calls = InvocationCounter()
    let now = Date(timeIntervalSince1970: 1_000)

    _ = try await store.execute(
      key: "create-reminder-1",
      fingerprint: "reminder_create:payload-a",
      now: now
    ) { "value-\(await calls.increment())" }
    let afterExpiry = try await store.execute(
      key: "create-reminder-1",
      fingerprint: "reminder_create:payload-a",
      now: now.addingTimeInterval(61)
    ) { "value-\(await calls.increment())" }

    #expect(afterExpiry == "value-2")
    #expect(await calls.value == 2)
  }

  @Test("bounds the completed-entry store")
  func boundsEntries() async throws {
    let store = ReminderIdempotencyStore(ttl: 60, maxEntries: 1)
    let calls = InvocationCounter()
    let now = Date(timeIntervalSince1970: 1_000)

    _ = try await store.execute(
      key: "first",
      fingerprint: "operation:first",
      now: now
    ) { "value-\(await calls.increment())" }
    _ = try await store.execute(
      key: "second",
      fingerprint: "operation:second",
      now: now.addingTimeInterval(1)
    ) { "value-\(await calls.increment())" }
    let reintroduced = try await store.execute(
      key: "first",
      fingerprint: "operation:first",
      now: now.addingTimeInterval(2)
    ) { "value-\(await calls.increment())" }

    #expect(reintroduced == "value-3")
    #expect(await calls.value == 3)
  }

  @Test("coalesces concurrent retries for the same key and payload")
  func coalescesConcurrentRetries() async throws {
    let store = ReminderIdempotencyStore()
    let calls = InvocationCounter()

    async let first: String = store.execute(
      key: "create-reminder-1",
      fingerprint: "reminder_create:payload-a"
    ) { "value-\(await calls.increment())" }
    async let retry: String = store.execute(
      key: "create-reminder-1",
      fingerprint: "reminder_create:payload-a"
    ) { "value-\(await calls.increment())" }

    #expect(try await first == "value-1")
    #expect(try await retry == "value-1")
    #expect(await calls.value == 1)
  }
}

private actor InvocationCounter {
  private(set) var value = 0

  func increment() -> Int {
    value += 1
    return value
  }
}
