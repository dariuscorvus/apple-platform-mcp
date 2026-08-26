import Foundation

public struct ReminderToolService: Sendable {
  private let repository: any ReminderRepository
  private let configuredMaxResults: Int
  private let policy: ReminderPolicy
  private let idempotencyStore: ReminderIdempotencyStore

  public init(
    repository: any ReminderRepository,
    maxResults: Int = 50,
    policy: ReminderPolicy = .denied,
    idempotencyStore: ReminderIdempotencyStore = ReminderIdempotencyStore()
  ) {
    self.repository = repository
    configuredMaxResults = max(1, maxResults)
    self.policy = policy
    self.idempotencyStore = idempotencyStore
  }

  public var maxResults: Int { configuredMaxResults }

  public var mutationMode: ReminderMutationMode { policy.mutationMode }

  public func authorizationStatus() async -> ReminderAuthorizationStatus {
    await repository.authorizationStatus()
  }

  /// The only prompt-capable Reminders operation. MCP tools call
  /// `requireReadAccess()` instead and never prompt implicitly.
  public func requestFullAccess() async throws -> ReminderAuthorizationStatus {
    try await repository.requestFullAccess()
  }

  public func listLists() async throws -> [ReminderList] {
    try await requireReadAccess()
    return try await repository.listLists()
  }

  public func listReminders(
    listID: ReminderListReference,
    completed: Bool? = nil,
    dueAfter: Date? = nil,
    dueBefore: Date? = nil,
    limit: Int? = nil
  ) async throws -> [ReminderItem] {
    try validate(listID)
    try await requireReadAccess()

    let boundedLimit = try boundedLimit(limit)
    if let dueAfter, let dueBefore, dueAfter >= dueBefore {
      throw ReminderError.invalidInput("due_after must be earlier than due_before")
    }
    let reminders = try await repository.listReminders(listID: listID)
    var filtered: [ReminderItem] = []
    filtered.reserveCapacity(min(reminders.count, boundedLimit))

    for reminder in reminders {
      if let completed, reminder.completed != completed {
        continue
      }
      if try !matchesDue(
        reminder.due,
        after: dueAfter,
        before: dueBefore
      ) {
        continue
      }
      filtered.append(reminder)
      if filtered.count == boundedLimit {
        break
      }
    }
    return filtered
  }

  public func getReminder(id: ReminderReference) async throws -> ReminderItem {
    try validate(id)
    try await requireReadAccess()
    return try await repository.getReminder(id: id)
  }

  public func createReminder(
    _ request: ReminderCreateRequest,
    idempotencyKey: String
  ) async throws -> ReminderItem {
    try policy.validateMutation()
    try validate(request)
    try await requireReadAccess()

    let fingerprint = try ReminderMutationFingerprint.make(
      operation: "reminder_create_reminder",
      payload: request
    )
    let repository = repository
    return try await idempotencyStore.execute(
      key: idempotencyKey,
      fingerprint: fingerprint
    ) {
      try await repository.createReminder(request)
    }
  }

  public func updateReminder(
    _ request: ReminderUpdateRequest,
    idempotencyKey: String
  ) async throws -> ReminderItem {
    try policy.validateMutation()
    try validate(request)
    try await requireReadAccess()

    let fingerprint = try ReminderMutationFingerprint.make(
      operation: "reminder_update_reminder",
      payload: request
    )
    let repository = repository
    return try await idempotencyStore.execute(
      key: idempotencyKey,
      fingerprint: fingerprint
    ) {
      try await repository.updateReminder(request)
    }
  }

  public func completeReminder(
    id: ReminderReference,
    idempotencyKey: String
  ) async throws -> ReminderItem {
    try policy.validateMutation()
    try validate(id)
    try await requireReadAccess()

    let fingerprint = try ReminderMutationFingerprint.make(
      operation: "reminder_complete_reminder",
      payload: ReminderReferenceMutationPayload(id: id)
    )
    let repository = repository
    return try await idempotencyStore.execute(
      key: idempotencyKey,
      fingerprint: fingerprint
    ) {
      try await repository.completeReminder(id: id)
    }
  }

  public func deleteReminder(
    id: ReminderReference,
    idempotencyKey: String
  ) async throws -> ReminderDeleteResult {
    try policy.validateMutation()
    try validate(id)
    try await requireReadAccess()

    let fingerprint = try ReminderMutationFingerprint.make(
      operation: "reminder_delete_reminder",
      payload: ReminderReferenceMutationPayload(id: id)
    )
    let repository = repository
    return try await idempotencyStore.execute(
      key: idempotencyKey,
      fingerprint: fingerprint
    ) {
      try await repository.deleteReminder(id: id)
    }
  }

  public func createList(
    _ request: ReminderListCreateRequest,
    idempotencyKey: String
  ) async throws -> ReminderList {
    try policy.validateMutation()
    try validate(request)
    try await requireReadAccess()

    let fingerprint = try ReminderMutationFingerprint.make(
      operation: "reminder_create_list",
      payload: request
    )
    let repository = repository
    return try await idempotencyStore.execute(
      key: idempotencyKey,
      fingerprint: fingerprint
    ) {
      try await repository.createList(request)
    }
  }

  public func updateList(
    _ request: ReminderListUpdateRequest,
    idempotencyKey: String
  ) async throws -> ReminderList {
    try policy.validateMutation()
    try validate(request)
    try await requireReadAccess()

    let fingerprint = try ReminderMutationFingerprint.make(
      operation: "reminder_update_list",
      payload: request
    )
    let repository = repository
    return try await idempotencyStore.execute(
      key: idempotencyKey,
      fingerprint: fingerprint
    ) {
      try await repository.updateList(request)
    }
  }

  public func deleteList(
    id: ReminderListReference,
    idempotencyKey: String
  ) async throws -> ReminderListDeleteResult {
    try policy.validateListDeletion()
    try validate(id)
    try await requireReadAccess()

    let fingerprint = try ReminderMutationFingerprint.make(
      operation: "reminder_delete_list",
      payload: ReminderListReferenceMutationPayload(id: id)
    )
    let repository = repository
    return try await idempotencyStore.execute(
      key: idempotencyKey,
      fingerprint: fingerprint
    ) {
      try await repository.deleteList(id: id)
    }
  }

  private func requireReadAccess() async throws {
    switch await repository.authorizationStatus() {
    case .fullAccess:
      return
    case .notDetermined:
      throw ReminderError.permissionRequired
    case .denied:
      throw ReminderError.permissionDenied
    case .restricted:
      throw ReminderError.permissionRestricted
    case .writeOnly:
      throw ReminderError.permissionWriteOnly
    case .unavailable:
      throw ReminderError.eventStoreUnavailable
    }
  }

  private func validate(_ listID: ReminderListReference) throws {
    guard listID.version == 1 else {
      throw ReminderError.unsupportedReferenceVersion
    }
    guard ReminderReferenceCodec.isValid(listID) else {
      throw ReminderError.invalidReference
    }
  }

  private func validate(_ reminderID: ReminderReference) throws {
    guard reminderID.version == 1 else {
      throw ReminderError.unsupportedReferenceVersion
    }
    guard ReminderReferenceCodec.isValid(reminderID) else {
      throw ReminderError.invalidReference
    }
  }

  private func validate(_ request: ReminderCreateRequest) throws {
    try validate(request.listID)
    try validateTitle(request.title)
    try validatePriority(request.priority)
  }

  private func validate(_ request: ReminderUpdateRequest) throws {
    try validate(request.id)
    guard request.hasChanges else {
      throw ReminderError.invalidInput("At least one Reminder field must be supplied for update")
    }

    switch request.listID {
    case .unchanged:
      break
    case .set(let value):
      try validate(value)
    case .clear:
      throw ReminderError.invalidInput("list_id cannot be cleared")
    }
    switch request.title {
    case .unchanged:
      break
    case .set(let value):
      try validateTitle(value)
    case .clear:
      throw ReminderError.invalidInput("title cannot be cleared")
    }
    switch request.notes {
    case .unchanged, .clear:
      break
    case .set:
      break
    }
    switch request.priority {
    case .unchanged:
      break
    case .set(let value):
      try validatePriority(value)
    case .clear:
      throw ReminderError.invalidInput("priority cannot be cleared")
    }
  }

  private func validate(_ request: ReminderListCreateRequest) throws {
    try validate(request.sourceListID)
    try validateListName(request.name)
  }

  private func validate(_ request: ReminderListUpdateRequest) throws {
    try validate(request.id)
    try validateListName(request.name)
  }

  private func validateTitle(_ title: String) throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ReminderError.invalidInput("title must not be empty")
    }
  }

  private func validatePriority(_ priority: Int) throws {
    guard (0...9).contains(priority) else {
      throw ReminderError.invalidInput("priority must be between 0 and 9")
    }
  }

  private func validateListName(_ name: String) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ReminderError.invalidInput("name must not be empty")
    }
  }

  private func boundedLimit(_ requested: Int?) throws -> Int {
    let limit = requested ?? 20
    guard limit > 0 else {
      throw ReminderError.invalidInput("limit must be greater than zero")
    }
    return min(limit, configuredMaxResults)
  }

  private func matchesDue(_ due: ReminderDue?, after: Date?, before: Date?) throws -> Bool {
    guard after != nil || before != nil else { return true }
    guard let due else { return false }
    guard let dueDate = due.comparisonDate() else {
      throw ReminderError.unsupportedDue
    }
    if let after, dueDate <= after { return false }
    if let before, dueDate >= before { return false }
    return true
  }
}

private struct ReminderReferenceMutationPayload: Codable, Sendable {
  let id: ReminderReference
}

private struct ReminderListReferenceMutationPayload: Codable, Sendable {
  let id: ReminderListReference
}
