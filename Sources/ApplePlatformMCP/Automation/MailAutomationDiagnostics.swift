import CoreServices
import Foundation
#if canImport(MailScriptingBridge)
  import MailScriptingBridge
#endif

public enum MailAutomationPermission: String, Codable, Equatable, Sendable {
  case notChecked = "not_checked"
  case allowed
  case needsConsent = "needs_consent"
  case denied
  case unavailable
}

/// Non-sensitive Mail.app and Apple Events status. This type never reads
/// accounts, mailboxes, messages, or message metadata.
public struct MailAutomationDiagnostics: Codable, Equatable, Sendable {
  public let mailAppInstalled: Bool
  public let mailAppRunning: Bool
  public let permission: MailAutomationPermission

  public init(
    mailAppInstalled: Bool,
    mailAppRunning: Bool,
    permission: MailAutomationPermission
  ) {
    self.mailAppInstalled = mailAppInstalled
    self.mailAppRunning = mailAppRunning
    self.permission = permission
  }

  public static func inspect() -> MailAutomationDiagnostics {
    guard let application = MailApplication(bundleIdentifier: "com.apple.mail") else {
      return MailAutomationDiagnostics(
        mailAppInstalled: false,
        mailAppRunning: false,
        permission: .unavailable
      )
    }

    guard application.isRunning else {
      return MailAutomationDiagnostics(
        mailAppInstalled: true,
        mailAppRunning: false,
        permission: .notChecked
      )
    }

    let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.mail")
    guard let address = target.aeDesc else {
      return MailAutomationDiagnostics(
        mailAppInstalled: true,
        mailAppRunning: true,
        permission: .unavailable
      )
    }

    let status = AEDeterminePermissionToAutomateTarget(
      address,
      typeWildCard,
      typeWildCard,
      false
    )
    let permission: MailAutomationPermission
    if status == OSStatus(noErr) {
      permission = .allowed
    } else if status == OSStatus(errAEEventWouldRequireUserConsent) {
      permission = .needsConsent
    } else if status == OSStatus(errAEEventNotPermitted) {
      permission = .denied
    } else {
      permission = .unavailable
    }

    return MailAutomationDiagnostics(
      mailAppInstalled: true,
      mailAppRunning: true,
      permission: permission
    )
  }

  /// Explicitly requests Automation consent during setup. MCP requests never
  /// call this method; they use `inspect()` and fail closed when consent is
  /// missing.
  public static func requestPermission() throws {
    let diagnostics = inspect()
    guard diagnostics.mailAppInstalled else {
      throw MailError.mailNotRunning
    }
    guard diagnostics.mailAppRunning else {
      throw MailError.mailNotRunning
    }

    switch diagnostics.permission {
    case .allowed:
      return
    case .denied:
      throw MailError.permissionDenied
    case .needsConsent:
      break
    case .unavailable, .notChecked:
      throw MailError.permissionDenied
    }

    guard let application = MailApplication(bundleIdentifier: "com.apple.mail") else {
      throw MailError.mailNotRunning
    }

    // Reading the app name is a harmless Apple Event. With a signed host and
    // NSAppleEventsUsageDescription, macOS uses this event to show consent.
    _ = application.name
  }
}
