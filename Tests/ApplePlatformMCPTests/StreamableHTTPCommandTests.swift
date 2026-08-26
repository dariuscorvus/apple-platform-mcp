import Foundation
import Testing

#if !XCODE_COMBINED_TEST_TARGET
  import ApplePlatformMCPKit
#endif

@Suite("Streamable HTTP command")
struct StreamableHTTPCommandTests {
  @Test("parses an explicit loopback HTTP endpoint")
  func parsesExplicitEndpoint() throws {
    #expect(
      try ApplePlatformMCPCommand.parse([
        "serve",
        "--transport", "streamable-http",
        "--host", "127.0.0.1",
        "--port", "8765",
      ])
        == .serve(
          transport: .streamableHTTP(
            host: "127.0.0.1",
            port: 8_765
          )))
  }

  @Test("defaults Streamable HTTP to the loopback interface")
  func defaultsToLoopback() throws {
    #expect(
      try ApplePlatformMCPCommand.parse([
        "serve", "--transport", "streamable-http",
      ])
        == .serve(
          transport: .streamableHTTP(
            host: "127.0.0.1",
            port: 8_765
          )))
  }

  @Test("accepts a configuration override for Streamable HTTP")
  func parsesHTTPConfigurationOverride() throws {
    let configurationURL = URL(
      fileURLWithPath: "/private/tmp/apple-platform-mcp-reminders-smoke.json"
    )

    #expect(
      try ApplePlatformMCPCommand.parse([
        "serve",
        "--transport", "streamable-http",
        "--config", configurationURL.path,
      ])
        == .serve(
          transport: .streamableHTTP(
            host: "127.0.0.1",
            port: 8_765
          ),
          configurationURL: configurationURL))
  }

  @Test("rejects a non-loopback HTTP bind address")
  func rejectsNonLoopbackHost() {
    #expect(throws: MailError.self) {
      try ApplePlatformMCPCommand.parse([
        "serve",
        "--transport", "streamable-http",
        "--host", "0.0.0.0",
        "--port", "8765",
      ])
    }
  }

  @Test("rejects an invalid TCP port", arguments: ["0", "65536"])
  func rejectsInvalidPort(_ port: String) {
    #expect(throws: MailError.self) {
      try ApplePlatformMCPCommand.parse([
        "serve",
        "--transport", "streamable-http",
        "--host", "127.0.0.1",
        "--port", port,
      ])
    }
  }
}
