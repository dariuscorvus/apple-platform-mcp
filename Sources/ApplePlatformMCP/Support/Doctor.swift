import Foundation
import Security

public enum DoctorCheckStatus: String, Codable, Equatable, Sendable {
  case pass
  case warning
  case fail
}

public struct DoctorCheck: Codable, Equatable, Sendable {
  public let name: String
  public let status: DoctorCheckStatus
  public let detail: String

  public init(name: String, status: DoctorCheckStatus, detail: String) {
    self.name = name
    self.status = status
    self.detail = detail
  }
}

public struct DoctorReport: Codable, Equatable, Sendable {
  public let serverName: String
  public let serverVersion: String
  public let macOSVersion: String
  public let policyMode: MailPolicy.Mode
  public let configurationPath: String
  public let checks: [DoctorCheck]

  public var exitCode: Int {
    checks.contains(where: { $0.status == .fail }) ? 1 : 0
  }

  public init(
    serverName: String,
    serverVersion: String,
    macOSVersion: String,
    policyMode: MailPolicy.Mode,
    configurationPath: String,
    checks: [DoctorCheck]
  ) {
    self.serverName = serverName
    self.serverVersion = serverVersion
    self.macOSVersion = macOSVersion
    self.policyMode = policyMode
    self.configurationPath = configurationPath
    self.checks = checks
  }
}

public enum ApplePlatformMCPDoctor {
  public static let serverName = "apple-platform-mcp"
  public static let serverVersion = ApplePlatformMCPBuildProvenance.serverVersion

  public static func inspect(
    configurationURL: URL = MailServerConfiguration.defaultURL,
    bundle: Bundle = .main
  ) -> DoctorReport {
    var checks: [DoctorCheck] = []
    let configuration: MailServerConfiguration

    do {
      configuration = try MailServerConfiguration.load(from: configurationURL)
      let detail =
        FileManager.default.fileExists(atPath: configurationURL.path)
        ? "Configuration loaded."
        : "No configuration file found; using safe defaults."
      checks.append(.init(name: "configuration", status: .pass, detail: detail))
    } catch {
      configuration = .default
      checks.append(
        .init(
          name: "configuration",
          status: .fail,
          detail: "The configuration file could not be loaded."
        ))
    }

    let mail = MailAutomationDiagnostics.inspect()
    switch mail.permission {
    case .allowed:
      checks.append(
        .init(
          name: "mail_automation",
          status: .pass,
          detail: "Mail.app is running and Apple Events access is allowed."
        ))
    case .notChecked:
      checks.append(
        .init(
          name: "mail_automation",
          status: .warning,
          detail: mail.mailAppInstalled
            ? "Mail.app is installed but not running. Open Mail.app before testing account access."
            : "Mail.app is not available."
        ))
    case .needsConsent:
      checks.append(
        .init(
          name: "mail_automation",
          status: .fail,
          detail: "macOS requires Automation consent for Mail.app."
        ))
    case .denied:
      checks.append(
        .init(
          name: "mail_automation",
          status: .fail,
          detail: "Automation access to Mail.app is denied."
        ))
    case .unavailable:
      checks.append(
        .init(
          name: "mail_automation",
          status: .fail,
          detail: mail.mailAppInstalled
            ? "The Mail.app automation target could not be inspected."
            : "Mail.app is not installed."
        ))
    }

    let usageDescription =
      bundle.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String
    checks.append(
      .init(
        name: "usage_description",
        status: usageDescription?.isEmpty == false ? .pass : .fail,
        detail: usageDescription?.isEmpty == false
          ? "NSAppleEventsUsageDescription is present."
          : "NSAppleEventsUsageDescription is missing from the executable Info.plist."
      ))

    let fullAccessUsageDescription =
      bundle.object(
        forInfoDictionaryKey: ReminderPermissionRequirements.fullAccessUsageDescriptionKey
      ) as? String
    let legacyUsageDescription =
      bundle.object(forInfoDictionaryKey: ReminderPermissionRequirements.legacyUsageDescriptionKey)
      as? String
    checks.append(
      .init(
        name: "reminder_usage_descriptions",
        status: fullAccessUsageDescription?.isEmpty == false
          && legacyUsageDescription?.isEmpty == false ? .pass : .fail,
        detail: fullAccessUsageDescription?.isEmpty == false
          && legacyUsageDescription?.isEmpty == false
          ? "Reminders Full Access and macOS 13 fallback usage descriptions are present."
          : "Reminders usage descriptions are missing from the executable Info.plist."
      ))

    let reminderPermission = EventKitReminderRepository.currentAuthorizationStatus()
    switch reminderPermission {
    case .fullAccess:
      checks.append(
        .init(
          name: "reminder_permission",
          status: .pass,
          detail: "Reminders Full Access is allowed."
        ))
    case .notDetermined:
      checks.append(
        .init(
          name: "reminder_permission",
          status: .warning,
          detail: "Reminders access has not been requested. Run doctor --request-reminders."
        ))
    case .denied:
      checks.append(
        .init(
          name: "reminder_permission",
          status: .fail,
          detail: "Reminders Full Access is denied."
        ))
    case .restricted:
      checks.append(
        .init(
          name: "reminder_permission",
          status: .fail,
          detail: "Reminders access is restricted by the system."
        ))
    case .writeOnly:
      checks.append(
        .init(
          name: "reminder_permission",
          status: .fail,
          detail: "Reminders access is write-only; this server requires Full Access."
        ))
    case .unavailable:
      checks.append(
        .init(
          name: "reminder_permission",
          status: .fail,
          detail: "The Reminders EventKit store is unavailable on this host."
        ))
    }

    checks.append(signingCheck(bundle: bundle))
    checks.append(
      .init(
        name: "scope",
        status: .pass,
        detail:
          "Mail.app and Reminders access is policy-controlled; Reminder mutations default to denied. No Accessibility or Full Disk Access requirement."
      ))

    return DoctorReport(
      serverName: serverName,
      serverVersion: serverVersion,
      macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      policyMode: configuration.policy.mode,
      configurationPath: configurationURL.path,
      checks: checks
    )
  }

  public static func requestAutomation(
    configurationURL: URL = MailServerConfiguration.defaultURL,
    bundle: Bundle = .main
  ) -> DoctorReport {
    do {
      try MailAutomationDiagnostics.requestPermission()
    } catch {
      // The follow-up report contains the normalized current state and the
      // ordinary doctor exit code. No Apple Event error is exposed.
    }
    return inspect(configurationURL: configurationURL, bundle: bundle)
  }

  public static func requestReminders(
    configurationURL: URL = MailServerConfiguration.defaultURL,
    bundle: Bundle = .main
  ) async -> DoctorReport {
    let repository = EventKitReminderRepository()
    _ = try? await repository.requestFullAccess()
    return inspect(configurationURL: configurationURL, bundle: bundle)
  }

  private static func signingCheck(bundle: Bundle) -> DoctorCheck {
    let executableURL =
      bundle.executableURL
      ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "apple-platform-mcp")
    var code: SecStaticCode?
    let createStatus = SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code)
    guard createStatus == errSecSuccess, let code else {
      return .init(
        name: "code_signing",
        status: .warning,
        detail: "The development executable is not signed."
      )
    }

    let validity = SecStaticCodeCheckValidity(code, [], nil)
    guard validity == errSecSuccess else {
      return .init(
        name: "code_signing",
        status: .warning,
        detail: validity == errSecCSUnsigned
          ? "The development executable is unsigned."
          : "The executable is not validly signed for distribution."
      )
    }

    var signingInformation: CFDictionary?
    let infoStatus = SecCodeCopySigningInformation(
      code,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &signingInformation
    )
    guard
      infoStatus == errSecSuccess,
      let dictionary = signingInformation as? [String: Any]
    else {
      return .init(
        name: "code_signing",
        status: .warning,
        detail: "The executable signature could not be inspected."
      )
    }

    let hasCertificates = (dictionary["certificates"] as? [Any])?.isEmpty == false
    guard hasCertificates else {
      return .init(
        name: "code_signing",
        status: .warning,
        detail: "The development executable is unsigned or ad hoc signed."
      )
    }

    let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    let hasAutomationEntitlement =
      entitlements?["com.apple.security.automation.apple-events"] as? Bool == true
    guard hasAutomationEntitlement else {
      return .init(
        name: "code_signing",
        status: .fail,
        detail: "The signed executable is missing the Apple Events entitlement."
      )
    }

    let signingFlags =
      (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    // Security.framework exposes the runtime-hardening bit as 0x10000 in the
    // static-code flags. Keep the value local because the C enum is not
    // imported by every Swift SDK version.
    guard signingFlags & 0x10000 != 0 else {
      return .init(
        name: "code_signing",
        status: .fail,
        detail: "The signed executable is missing the Hardened Runtime flag."
      )
    }

    return .init(
      name: "code_signing",
      status: .pass,
      detail: "The executable is signed with Hardened Runtime and the Apple Events entitlement."
    )
  }
}
