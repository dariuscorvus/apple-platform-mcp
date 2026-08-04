import Foundation
import MCP
import Testing

#if !XCODE_COMBINED_TEST_TARGET
  import ApplePlatformMCPKit
#endif

private actor BlockingMCPHandler {
  private var started = false
  private var startWaiter: CheckedContinuation<Void, Never>?
  private var responseWaiter: CheckedContinuation<HTTPResponse, Never>?

  func handle(_ request: HTTPRequest) async -> HTTPResponse {
    started = true
    startWaiter?.resume()
    startWaiter = nil
    return await withCheckedContinuation { responseWaiter = $0 }
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startWaiter = $0 }
  }

  func release() {
    responseWaiter?.resume(returning: .accepted())
    responseWaiter = nil
  }
}

private actor HTTPFakeMailRepository: MailRepository {
  func listAccounts(includeDisabled: Bool) async throws -> [MailAccountModel] { [] }

  func listMailboxes(
    accountID: AccountReference,
    includeCounts: Bool
  ) async throws -> [Mailbox] { [] }

  func searchMessages(_ query: MailSearchQuery) async throws -> MailSearchPage {
    MailSearchPage(messages: [])
  }

  func getMessage(
    id: MessageReference,
    includeBody: Bool,
    bodyFormat: MailBodyFormat,
    includeAttachmentMetadata: Bool,
    maxBodyBytes: Int
  ) async throws -> MailMessageRecord {
    throw MailError.messageNotFound
  }
}

@Suite("Streamable HTTP routing")
struct StreamableHTTPRoutingTests {
  @Test("liveness is a non-sensitive process check")
  func liveness() async throws {
    let router = ApplePlatformMCPHTTPRouter(
      mcpHandler: { _ in .accepted() },
      readinessProbe: { true }
    )

    let response = await router.handle(
      HTTPRequest(method: "GET", path: "/health/live")
    )

    #expect(response.statusCode == 200)
    #expect(response.headers["Content-Type"] == "application/json")
    let body = try #require(response.bodyData)
    let json = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: String]
    )
    #expect(json == ["status": "live"])
  }

  @Test("readiness failure is sanitized")
  func readinessFailure() async throws {
    let router = ApplePlatformMCPHTTPRouter(
      mcpHandler: { _ in .accepted() },
      readinessProbe: { false }
    )

    let response = await router.handle(
      HTTPRequest(method: "GET", path: "/health/ready")
    )

    #expect(response.statusCode == 503)
    let body = try #require(response.bodyData)
    let json = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: String]
    )
    #expect(json == ["status": "not_ready"])
  }

  @Test("forwards only the canonical MCP resource")
  func forwardsCanonicalMCPResource() async {
    let router = ApplePlatformMCPHTTPRouter(
      mcpHandler: { _ in .accepted() },
      readinessProbe: { true }
    )

    let mcpResponse = await router.handle(
      HTTPRequest(method: "POST", path: "/mcp")
    )
    let otherResponse = await router.handle(
      HTTPRequest(method: "POST", path: "/other")
    )

    #expect(mcpResponse.statusCode == 202)
    #expect(otherResponse.statusCode == 404)
  }

  @Test("performs an MCP initialize round trip")
  func initializesMCP() async throws {
    let server = Server(
      name: "http-test",
      version: "1.0.0",
      capabilities: .init()
    )
    let runtime = ApplePlatformMCPStreamableHTTPRuntime(
      server: server,
      readinessProbe: { true }
    )
    try await runtime.start()

    let response = await runtime.handle(
      HTTPRequest(
        method: "POST",
        headers: [
          "Accept": "application/json",
          "Content-Type": "application/json",
        ],
        body: Data(
          #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#
            .utf8
        ),
        path: "/mcp"
      )
    )
    await runtime.stop()

    #expect(response.statusCode == 200)
    let body = try #require(response.bodyData)
    let json = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(json["result"] != nil)
  }

  @Test("bounds unanswered MCP requests")
  func timesOutUnansweredRequest() async throws {
    let transport = ApplePlatformMCPStatelessHTTPTransport(
      responseTimeout: .milliseconds(10)
    )
    try await transport.connect()

    let response = await transport.handleRequest(
      HTTPRequest(
        method: "POST",
        headers: [
          "Accept": "application/json",
          "Content-Type": "application/json",
        ],
        body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8),
        path: "/mcp"
      )
    )
    await transport.disconnect()

    #expect(response.statusCode == 504)
  }

  @Test("enforces MCP HTTP request headers")
  func enforcesHTTPHeaders() async throws {
    let transport = ApplePlatformMCPStatelessHTTPTransport()
    try await transport.connect()
    let body = Data(#"{"jsonrpc":"2.0","method":"notifications/ping"}"#.utf8)
    let validHeaders = [
      "Host": "127.0.0.1:8765",
      "Accept": "application/json",
      "Content-Type": "application/json",
      "MCP-Protocol-Version": "2025-06-18",
    ]
    let invalidCases: [([String: String], Int)] = [
      (validHeaders.merging(["Host": "example.com"], uniquingKeysWith: { _, new in new }), 421),
      (
        validHeaders.merging(
          ["Origin": "https://example.com"], uniquingKeysWith: { _, new in new }), 403
      ),
      (validHeaders.filter { $0.key != "Accept" }, 406),
      (
        validHeaders.merging(
          ["Content-Type": "text/plain"], uniquingKeysWith: { _, new in new }), 415
      ),
      (
        validHeaders.merging(
          ["MCP-Protocol-Version": "1900-01-01"], uniquingKeysWith: { _, new in new }), 400
      ),
    ]

    for (headers, expectedStatus) in invalidCases {
      let response = await transport.handleRequest(
        HTTPRequest(method: "POST", headers: headers, body: body, path: "/mcp")
      )
      #expect(response.statusCode == expectedStatus)
    }
    await transport.disconnect()
  }

  @Test("rejects malformed JSON-RPC before dispatch")
  func rejectsMalformedJSONRPC() async throws {
    let transport = ApplePlatformMCPStatelessHTTPTransport(
      responseTimeout: .milliseconds(10)
    )
    try await transport.connect()

    let response = await transport.handleRequest(
      HTTPRequest(
        method: "POST",
        headers: [
          "Accept": "application/json",
          "Content-Type": "application/json",
        ],
        body: Data(#"{"id":1,"method":"ping"}"#.utf8),
        path: "/mcp"
      )
    )
    await transport.disconnect()

    #expect(response.statusCode == 400)
  }

  @Test("quarantines a timed-out JSON-RPC ID from late-response reuse")
  func quarantinesTimedOutID() async throws {
    let transport = ApplePlatformMCPStatelessHTTPTransport(responseTimeout: .milliseconds(10))
    try await transport.connect()
    let body = Data(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#.utf8)
    let request = HTTPRequest(
      method: "POST",
      headers: [
        "Accept": "application/json",
        "Content-Type": "application/json",
        "MCP-Protocol-Version": "2025-03-26",
      ],
      body: body,
      path: "/mcp"
    )

    let timedOut = await transport.handleRequest(request)
    #expect(timedOut.statusCode == 504)
    let reused = await transport.handleRequest(request)
    #expect(reused.statusCode == 409)
    await transport.disconnect()
  }

  @Test("keeps numeric and string JSON-RPC IDs distinct")
  func keepsTypedIDsDistinct() async throws {
    let transport = ApplePlatformMCPStatelessHTTPTransport(responseTimeout: .seconds(1))
    try await transport.connect()

    let numericBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
    let stringBody = Data(#"{"jsonrpc":"2.0","id":"1","method":"ping"}"#.utf8)
    let headers = [
      "Accept": "application/json",
      "Content-Type": "application/json",
      "MCP-Protocol-Version": "2025-03-26",
    ]

    let numericTask = Task {
      await transport.handleRequest(
        HTTPRequest(method: "POST", headers: headers, body: numericBody, path: "/mcp")
      )
    }
    let stringTask = Task {
      await transport.handleRequest(
        HTTPRequest(method: "POST", headers: headers, body: stringBody, path: "/mcp")
      )
    }

    try await Task.sleep(for: .milliseconds(10))
    #expect(await transport.httpRequestContext(for: .number(1))?.body == numericBody)
    #expect(await transport.httpRequestContext(for: .string("1"))?.body == stringBody)

    await transport.disconnect()
    _ = await numericTask.value
    _ = await stringTask.value
  }

  @Test("bounds concurrent MCP requests")
  func boundsConcurrentRequests() async {
    let handler = BlockingMCPHandler()
    let router = ApplePlatformMCPHTTPRouter(
      maximumConcurrentMCPRequests: 1,
      mcpHandler: { request in await handler.handle(request) },
      readinessProbe: { true }
    )
    let request = HTTPRequest(method: "POST", path: "/mcp")
    let first = Task { await router.handle(request) }
    await handler.waitUntilStarted()

    let rejected = await router.handle(request)
    await handler.release()
    _ = await first.value

    #expect(rejected.statusCode == 429)
  }

  @Test("publishes only the five read-only Mail tools over HTTP")
  func publishesReadOnlyToolCatalog() async throws {
    let service = MailToolService(repository: HTTPFakeMailRepository())
    let server = await ApplePlatformMCPServer(service: service).makeServer()
    let runtime = ApplePlatformMCPStreamableHTTPRuntime(
      server: server,
      readinessProbe: { true }
    )
    try await runtime.start()

    _ = await runtime.handle(
      mcpRequest(
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#
      )
    )
    _ = await runtime.handle(
      mcpRequest(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    )
    let response = await runtime.handle(
      mcpRequest(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
    )
    await runtime.stop()

    #expect(response.statusCode == 200)
    let body = try #require(response.bodyData)
    let json = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    let result = try #require(json["result"] as? [String: Any])
    let tools = try #require(result["tools"] as? [[String: Any]])
    let names = Set(tools.compactMap { $0["name"] as? String })
    #expect(
      names
        == Set([
          "mail_server_info",
          "mail_list_accounts",
          "mail_list_mailboxes",
          "mail_search_messages",
          "mail_get_message",
        ]))
  }

  private func mcpRequest(_ body: String) -> HTTPRequest {
    HTTPRequest(
      method: "POST",
      headers: [
        "Accept": "application/json",
        "Content-Type": "application/json",
        "MCP-Protocol-Version": "2025-06-18",
      ],
      body: Data(body.utf8),
      path: "/mcp"
    )
  }
}
