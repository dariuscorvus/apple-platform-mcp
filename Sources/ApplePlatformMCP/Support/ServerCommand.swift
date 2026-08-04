import Foundation

public enum ApplePlatformMCPTransport: String, Equatable, Sendable {
  case stdio
}

public enum ApplePlatformMCPCommand: Equatable, Sendable {
  case doctor(requestAutomation: Bool)
  case serve(transport: ApplePlatformMCPTransport)

  public static func parse(_ arguments: [String]) throws -> ApplePlatformMCPCommand {
    guard let command = arguments.first else {
      return .serve(transport: .stdio)
    }

    switch command {
    case "doctor":
      switch Array(arguments.dropFirst()) {
      case []:
        return .doctor(requestAutomation: false)
      case ["--request-automation"]:
        return .doctor(requestAutomation: true)
      default:
        throw MailError.invalidInput("Usage: apple-platform-mcp doctor [--request-automation]")
      }

    case "serve":
      switch Array(arguments.dropFirst()) {
      case ["--transport", ApplePlatformMCPTransport.stdio.rawValue]:
        return .serve(transport: .stdio)
      default:
        throw MailError.invalidInput(
          "Only --transport stdio is currently supported. Streamable HTTP will be added separately."
        )
      }

    default:
      throw MailError.invalidInput(
        "Usage: apple-platform-mcp [serve --transport stdio|doctor [--request-automation]]"
      )
    }
  }
}
