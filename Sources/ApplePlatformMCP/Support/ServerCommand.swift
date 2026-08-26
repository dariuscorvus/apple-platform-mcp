import Foundation

public enum ApplePlatformMCPTransport: Equatable, Sendable {
  case stdio
  case streamableHTTP(host: String, port: Int)
}

public enum ApplePlatformMCPCommand: Equatable, Sendable {
  case doctor(requestAutomation: Bool)
  case doctorReminders
  case serve(
    transport: ApplePlatformMCPTransport,
    configurationURL: URL? = nil
  )

  private static let serveUsage =
    "Usage: apple-platform-mcp serve --transport stdio|streamable-http [--host 127.0.0.1 --port 8765] [--config /absolute/path]"

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
      case ["--request-reminders"]:
        return .doctorReminders
      default:
        throw MailError.invalidInput(
          "Usage: apple-platform-mcp doctor [--request-automation|--request-reminders]"
        )
      }

    case "serve":
      var serveArguments = Array(arguments.dropFirst())
      let configurationURL = try configurationOverride(from: &serveArguments)
      if serveArguments == ["--transport", "stdio"] {
        return .serve(transport: .stdio, configurationURL: configurationURL)
      }
      if serveArguments == ["--transport", "streamable-http"] {
        return .serve(
          transport: .streamableHTTP(host: "127.0.0.1", port: 8_765),
          configurationURL: configurationURL
        )
      }
      if serveArguments.count == 6,
        serveArguments[0] == "--transport",
        serveArguments[1] == "streamable-http",
        serveArguments[2] == "--host",
        serveArguments[4] == "--port"
      {
        guard serveArguments[3] == "127.0.0.1" else {
          throw MailError.invalidInput(
            "Streamable HTTP must bind to 127.0.0.1. Non-loopback listeners are disabled."
          )
        }
        guard let port = Int(serveArguments[5]), (1...65_535).contains(port) else {
          throw MailError.invalidInput("The HTTP port must be an integer from 1 through 65535.")
        }
        return .serve(
          transport: .streamableHTTP(host: serveArguments[3], port: port),
          configurationURL: configurationURL
        )
      }
      throw MailError.invalidInput(serveUsage)

    default:
      throw MailError.invalidInput(
        "Usage: apple-platform-mcp [serve --transport stdio|streamable-http [--host 127.0.0.1 --port 8765] [--config /absolute/path]|doctor [--request-automation|--request-reminders]]"
      )
    }
  }

  private static func configurationOverride(from arguments: inout [String]) throws -> URL? {
    guard let configurationIndex = arguments.firstIndex(of: "--config") else {
      return nil
    }
    guard configurationIndex == arguments.count - 2 else {
      throw MailError.invalidInput(serveUsage)
    }

    let path = arguments[configurationIndex + 1]
    guard path.hasPrefix("/") else {
      throw MailError.invalidInput("The --config path must be absolute.")
    }

    arguments.removeLast(2)
    return URL(fileURLWithPath: path)
  }
}
