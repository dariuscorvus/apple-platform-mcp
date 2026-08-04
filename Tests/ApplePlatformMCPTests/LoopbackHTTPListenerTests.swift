import Foundation
import MCP
import Testing

#if !XCODE_COMBINED_TEST_TARGET
  import ApplePlatformMCPKit
#endif

@Suite("Loopback HTTP listener", .serialized)
struct LoopbackHTTPListenerTests {
  @Test("rejects non-loopback binding at the listener boundary")
  func rejectsNonLoopbackBinding() async {
    let router = ApplePlatformMCPHTTPRouter(
      mcpHandler: { _ in .accepted() },
      readinessProbe: { true }
    )
    let listener = ApplePlatformMCPHTTPServer(
      host: "0.0.0.0",
      port: 0,
      router: router
    )

    await #expect(throws: MailError.self) {
      try await listener.start()
    }
    await listener.stop()
  }

  @Test("rejects invalid authority before health routing")
  func rejectsInvalidAuthority() async throws {
    let router = ApplePlatformMCPHTTPRouter(
      mcpHandler: { _ in .accepted() },
      readinessProbe: { true }
    )
    let listener = ApplePlatformMCPHTTPServer(host: "127.0.0.1", port: 0, router: router)
    let port = try await listener.start()

    var wrongHost = URLRequest(
      url: try #require(URL(string: "http://127.0.0.1:\(port)/health/live")))
    wrongHost.setValue("example.com", forHTTPHeaderField: "Host")
    let (_, hostResponse) = try await URLSession.shared.data(for: wrongHost)
    #expect((hostResponse as? HTTPURLResponse)?.statusCode == 421)

    var wrongOrigin = URLRequest(
      url: try #require(URL(string: "http://127.0.0.1:\(port)/health/live")))
    wrongOrigin.setValue("https://example.com", forHTTPHeaderField: "Origin")
    let (_, originResponse) = try await URLSession.shared.data(for: wrongOrigin)
    #expect((originResponse as? HTTPURLResponse)?.statusCode == 403)

    await listener.stop()
  }

  @Test("serves liveness over an ephemeral loopback port")
  func servesLiveness() async throws {
    let router = ApplePlatformMCPHTTPRouter(
      mcpHandler: { _ in .accepted() },
      readinessProbe: { true }
    )
    let listener = ApplePlatformMCPHTTPServer(
      host: "127.0.0.1",
      port: 0,
      router: router
    )
    let port = try await listener.start()

    let (data, response) = try await URLSession.shared.data(
      from: URL(string: "http://127.0.0.1:\(port)/health/live")!
    )
    await listener.stop()

    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let json = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: String]
    )
    #expect(json == ["status": "live"])
  }

  @Test("rejects an oversized request before MCP dispatch")
  func rejectsOversizedRequest() async throws {
    let router = ApplePlatformMCPHTTPRouter(
      mcpHandler: { _ in .accepted() },
      readinessProbe: { true }
    )
    let listener = ApplePlatformMCPHTTPServer(
      host: "127.0.0.1",
      port: 0,
      maxRequestBodyBytes: 32,
      router: router
    )
    let port = try await listener.start()
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
    request.httpMethod = "POST"
    request.httpBody = Data(repeating: 65, count: 33)

    let (_, response) = try await URLSession.shared.data(for: request)
    await listener.stop()

    #expect((response as? HTTPURLResponse)?.statusCode == 413)
  }

  @Test("serves an MCP initialize request over HTTP")
  func servesMCPInitialize() async throws {
    let runtime = ApplePlatformMCPStreamableHTTPRuntime(
      server: Server(
        name: "http-listener-test",
        version: "1.0.0",
        capabilities: .init()
      ),
      readinessProbe: { true }
    )
    try await runtime.start()
    let listener = ApplePlatformMCPHTTPServer(
      host: "127.0.0.1",
      port: 0,
      router: runtime.router
    )
    let port = try await listener.start()
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#
        .utf8
    )

    let (data, response) = try await URLSession.shared.data(for: request)
    await listener.stop()
    await runtime.stop()

    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let json = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(json["result"] != nil)
  }
}
