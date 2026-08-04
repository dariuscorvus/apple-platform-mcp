import Foundation

public enum ApplePlatformMCPTransport: Equatable, Sendable {
  case stdio
  case streamableHTTP(host: String, port: Int)
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
      let serveArguments = Array(arguments.dropFirst())
      if serveArguments == ["--transport", "stdio"] {
        return .serve(transport: .stdio)
      }
      if serveArguments == ["--transport", "streamable-http"] {
        return .serve(
          transport: .streamableHTTP(host: "127.0.0.1", port: 8_765)
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
          transport: .streamableHTTP(host: serveArguments[3], port: port)
        )
      }
      throw MailError.invalidInput(
        "Usage: apple-platform-mcp serve --transport stdio|streamable-http [--host 127.0.0.1 --port 8765]"
      )

    default:
      throw MailError.invalidInput(
        "Usage: apple-platform-mcp [serve --transport stdio|streamable-http [--host 127.0.0.1 --port 8765]|doctor [--request-automation]]"
      )
    }
  }
}
