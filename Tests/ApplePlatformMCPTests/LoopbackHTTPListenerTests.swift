import Darwin
import Foundation
import MCP
import Testing

#if !XCODE_COMBINED_TEST_TARGET
  import ApplePlatformMCPKit
#endif

private actor DisconnectAwareHTTPHandler {
  private var started = false
  private var cancelled = false

  func handle() async -> HTTPResponse {
    started = true
    do {
      try await Task.sleep(for: .seconds(2))
    } catch is CancellationError {
      cancelled = true
    } catch {}
    return .accepted()
  }

  func hasStarted() -> Bool {
    started
  }

  func wasCancelled() -> Bool {
    cancelled
  }
}

private func eventually(
  timeout: Duration = .seconds(1),
  condition: @escaping @Sendable () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return await condition()
}

private func openLoopbackSocket(port: Int, request: Data) throws -> Int32 {
  let descriptor = socket(AF_INET, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw POSIXError(.ENOTCONN) }
  var address = sockaddr_in(
    sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
    sin_family: sa_family_t(AF_INET),
    sin_port: in_port_t(port).bigEndian,
    sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
    sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
  )
  let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard connected == 0 else {
    close(descriptor)
    throw POSIXError(.ENOTCONN)
  }
  let sentAll = request.withUnsafeBytes { bytes in
    var offset = 0
    while offset < bytes.count {
      let sent = send(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset, 0)
      guard sent > 0 else { return false }
      offset += sent
    }
    return true
  }
  guard sentAll else {
    close(descriptor)
    throw POSIXError(.EIO)
  }
  return descriptor
}

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

  @Test("cancels MCP routing when the HTTP client disconnects")
  func cancelsRoutingAfterClientDisconnect() async throws {
    let handler = DisconnectAwareHTTPHandler()
    let router = ApplePlatformMCPHTTPRouter(
      mcpHandler: { _ in await handler.handle() },
      readinessProbe: { true }
    )
    let listener = ApplePlatformMCPHTTPServer(host: "127.0.0.1", port: 0, router: router)
    let port = try await listener.start()
    let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
    let request = """
      POST /mcp HTTP/1.1\r
      Host: 127.0.0.1:\(port)\r
      Accept: application/json\r
      Content-Type: application/json\r
      Content-Length: \(body.utf8.count)\r
      \r
      \(body)
      """
    let descriptor = try openLoopbackSocket(port: port, request: Data(request.utf8))
    let started = await eventually { await handler.hasStarted() }
    #expect(started)
    guard started else {
      close(descriptor)
      await listener.stop()
      return
    }
    var reset = linger(l_onoff: 1, l_linger: 0)
    setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_LINGER,
      &reset,
      socklen_t(MemoryLayout<linger>.size)
    )
    close(descriptor)
    let wasCancelled = await eventually { await handler.wasCancelled() }
    await listener.stop()

    #expect(wasCancelled)
  }

  @Test("closes a pipelined connection without out-of-order responses")
  func closesPipelinedConnectionSilently() async throws {
    let handler = DisconnectAwareHTTPHandler()
    let router = ApplePlatformMCPHTTPRouter(
      mcpHandler: { _ in await handler.handle() },
      readinessProbe: { true }
    )
    let listener = ApplePlatformMCPHTTPServer(
      host: "127.0.0.1",
      port: 0,
      router: router
    )
    let port = try await listener.start()
    let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
    let request = """
      POST /mcp HTTP/1.1\r
      Host: 127.0.0.1:\(port)\r
      Accept: application/json\r
      Content-Type: application/json\r
      MCP-Protocol-Version: 2025-03-26\r
      Content-Length: \(body.utf8.count)\r
      \r
      \(body)
      """
    let descriptor = try openLoopbackSocket(
      port: port,
      request: Data((request + request).utf8)
    )
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &timeout,
      socklen_t(MemoryLayout<timeval>.size)
    )
    var buffer = [UInt8](repeating: 0, count: 1_024)
    let bytesRead = recv(descriptor, &buffer, buffer.count, 0)
    close(descriptor)
    await listener.stop()

    #expect(bytesRead <= 0)
  }
}
