import Foundation

public enum ReminderMutationMode: String, Codable, Equatable, Sendable {
  case denied
  case allowed
  case confirmationRequired = "confirmation_required"
}

/// Reminder writes are deliberately independent from Mail mutation settings.
/// A confirmation boundary is not implemented yet, so that mode remains
/// fail-closed.
public struct ReminderPolicy: Codable, Equatable, Sendable {
  public let mutationMode: ReminderMutationMode
  public let listDeleteEnabled: Bool

  public init(
    mutationMode: ReminderMutationMode = .denied,
    listDeleteEnabled: Bool = false
  ) {
    self.mutationMode = mutationMode
    self.listDeleteEnabled = listDeleteEnabled
  }

  public static let denied = ReminderPolicy()

  public func validateMutation() throws {
    switch mutationMode {
    case .allowed:
      return
    case .denied:
      throw ReminderError.policyDenied("Reminder mutations are disabled by policy.")
    case .confirmationRequired:
      throw ReminderError.policyDenied(
        "Reminder mutations require explicit confirmation, which is not available in this transport."
      )
    }
  }

  public func validateListDeletion() throws {
    try validateMutation()
    guard listDeleteEnabled else {
      throw ReminderError.policyDenied("Reminder list deletion is disabled by policy.")
    }
  }
}
