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

private actor CancellationAwareHandler {
  private var started = false
  private var cancelled = false

  func handle() async throws {
    started = true
    do {
      try await Task.sleep(for: .seconds(5))
    } catch is CancellationError {
      cancelled = true
      throw CancellationError()
    }
  }

  func hasStarted() -> Bool {
    started
  }

  func wasCancelled() -> Bool {
    cancelled
  }
}

private actor MessageCollector {
  private var messages: [Data] = []

  func append(_ message: Data) {
    messages.append(message)
  }

  func count() -> Int {
    messages.count
  }

  func snapshot() -> [Data] {
    messages
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

  func sendMessage(_ request: MailSendRequest) async throws -> MailSendResult {
    throw MailError.unsupportedByAccount
  }

  func createDraft(_ request: MailDraftRequest) async throws -> MailDraftResult {
    throw MailError.unsupportedByAccount
  }

  func moveMessage(
    id: MessageReference,
    to mailboxID: MailboxReference
  ) async throws -> MailMessageMutationResult {
    throw MailError.unsupportedByAccount
  }

  func trashMessage(_ id: MessageReference) async throws -> MailMessageMutationResult {
    throw MailError.unsupportedByAccount
  }

  func updateMessage(
    _ request: MailMessageUpdateRequest
  ) async throws -> MailMessageMutationResult {
    throw MailError.unsupportedByAccount
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

  @Test("isolates late responses with per-attempt internal IDs")
  func isolatesLateResponseFromReusedExternalID() async throws {
    let transport = ApplePlatformMCPStatelessHTTPTransport(responseTimeout: .milliseconds(100))
    let collector = MessageCollector()
    try await transport.connect()
    let receiveTask = Task {
      for try await message in await transport.receive() {
        await collector.append(message)
      }
    }
    let request = mcpRequest(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)

    let first = await transport.handleRequest(request)
    #expect(first.statusCode == 504)
    #expect(await eventually { await collector.count() >= 2 })
    let firstMessages = await collector.snapshot()
    let firstRequest = try #require(
      JSONSerialization.jsonObject(with: firstMessages[0]) as? [String: Any]
    )
    let internalA = try #require(firstRequest["id"] as? String)
    let firstCancellation = try #require(
      JSONSerialization.jsonObject(with: firstMessages[1]) as? [String: Any]
    )
    let firstCancellationParameters = try #require(
      firstCancellation["params"] as? [String: Any]
    )
    #expect(firstCancellationParameters["requestId"] as? String == internalA)

    let secondTask = Task { await transport.handleRequest(request) }
    #expect(await eventually { await collector.count() >= 3 })
    let secondMessages = await collector.snapshot()
    let secondRequest = try #require(
      JSONSerialization.jsonObject(with: secondMessages[2]) as? [String: Any]
    )
    let internalB = try #require(secondRequest["id"] as? String)
    #expect(internalB != internalA)

    try await transport.send(
      Data(#"{"jsonrpc":"2.0","id":"\#(internalA)","result":{}}"#.utf8)
    )
    #expect(await transport.httpRequestContext(for: .string(internalB)) != nil)
    try await transport.send(
      Data(#"{"jsonrpc":"2.0","id":"\#(internalB)","result":{}}"#.utf8)
    )
    let second = await secondTask.value
    let responseBody = try #require(second.bodyData)
    let responseJSON = try #require(
      JSONSerialization.jsonObject(with: responseBody) as? [String: Any]
    )

    #expect(second.statusCode == 200)
    #expect((responseJSON["id"] as? NSNumber)?.intValue == 7)
    await transport.disconnect()
    receiveTask.cancel()
  }

  @Test("translates client cancellation to the active internal ID")
  func translatesClientCancellation() async throws {
    let transport = ApplePlatformMCPStatelessHTTPTransport(responseTimeout: .seconds(1))
    let collector = MessageCollector()
    try await transport.connect()
    let receiveTask = Task {
      for try await message in await transport.receive() {
        await collector.append(message)
      }
    }
    let responseTask = Task {
      await transport.handleRequest(
        mcpRequest(#"{"jsonrpc":"2.0","id":"external","method":"tools/call"}"#)
      )
    }
    #expect(await eventually { await collector.count() >= 1 })
    let requestJSON = try #require(
      JSONSerialization.jsonObject(with: await collector.snapshot()[0]) as? [String: Any]
    )
    let internalID = try #require(requestJSON["id"] as? String)

    let accepted = await transport.handleRequest(
      mcpRequest(
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"external","reason":"client request"}}"#
      )
    )
    #expect(await eventually { await collector.count() >= 2 })
    let messages = await collector.snapshot()
    let cancellation = try #require(
      JSONSerialization.jsonObject(with: messages[1]) as? [String: Any]
    )
    let parameters = try #require(cancellation["params"] as? [String: Any])

    #expect(accepted.statusCode == 202)
    #expect(parameters["requestId"] as? String == internalID)
    let originalResponse = await responseTask.value
    #expect(originalResponse.statusCode == 499)
    await transport.disconnect()
    receiveTask.cancel()
  }

  @Test("cancels SDK work with the internal ID when an HTTP request times out")
  func cancelsTimedOutRequest() async throws {
    let transport = ApplePlatformMCPStatelessHTTPTransport(responseTimeout: .milliseconds(10))
    let collector = MessageCollector()
    try await transport.connect()
    let receiveTask = Task {
      for try await message in await transport.receive() {
        await collector.append(message)
      }
    }

    let response = await transport.handleRequest(
      mcpRequest(#"{"jsonrpc":"2.0","id":"slow","method":"tools/call"}"#)
    )
    #expect(await eventually { await collector.count() >= 2 })
    let received = await collector.snapshot()
    await transport.disconnect()
    receiveTask.cancel()

    #expect(response.statusCode == 504)
    let request = try #require(
      JSONSerialization.jsonObject(with: received[0]) as? [String: Any]
    )
    let internalID = try #require(request["id"] as? String)
    #expect(internalID != "slow")
    let cancellation = try #require(
      JSONSerialization.jsonObject(with: received[1]) as? [String: Any]
    )
    #expect(cancellation["method"] as? String == "notifications/cancelled")
    let parameters = try #require(cancellation["params"] as? [String: Any])
    #expect(parameters["requestId"] as? String == internalID)
    #expect(parameters["reason"] as? String == "HTTP request timed out")
  }

  @Test("cancels MCP work when the HTTP response task is cancelled")
  func cancelsDisconnectedHTTPRequest() async throws {
    let transport = ApplePlatformMCPStatelessHTTPTransport(responseTimeout: .seconds(1))
    let collector = MessageCollector()
    try await transport.connect()
    let receiveTask = Task {
      for try await message in await transport.receive() {
        await collector.append(message)
      }
    }

    let responseTask = Task {
      await transport.handleRequest(
        mcpRequest(#"{"jsonrpc":"2.0","id":"disconnected","method":"tools/call"}"#)
      )
    }
    #expect(await eventually { await collector.count() >= 1 })
    responseTask.cancel()
    let response = await responseTask.value
    #expect(await eventually { await collector.count() >= 2 })
    let received = await collector.snapshot()
    await transport.disconnect()
    receiveTask.cancel()

    #expect(response.statusCode == 499)
    let request = try #require(
      JSONSerialization.jsonObject(with: received[0]) as? [String: Any]
    )
    let internalID = try #require(request["id"] as? String)
    let cancellation = try #require(
      JSONSerialization.jsonObject(with: received[1]) as? [String: Any]
    )
    let parameters = try #require(cancellation["params"] as? [String: Any])
    #expect(parameters["requestId"] as? String == internalID)
    #expect(parameters["reason"] as? String == "HTTP client disconnected")
  }

  @Test("timeout cancellation reaches a registered SDK handler")
  func cancelsRunningSDKHandler() async throws {
    let handler = CancellationAwareHandler()
    let server = Server(name: "cancellation-test", version: "1.0.0", capabilities: .init())
    let transport = ApplePlatformMCPStatelessHTTPTransport(responseTimeout: .milliseconds(100))
    try await server.start(transport: transport)
    _ = await server.withMethodHandler(Ping.self) { _ in
      try await handler.handle()
      return Empty()
    }

    let response = await transport.handleRequest(
      mcpRequest(#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)
    )
    let wasCancelled = await eventually { await handler.wasCancelled() }
    await server.stop()

    #expect(response.statusCode == 504)
    #expect(wasCancelled)
  }

  @Test("keeps numeric and string JSON-RPC IDs distinct")
  func keepsTypedIDsDistinct() async throws {
    let transport = ApplePlatformMCPStatelessHTTPTransport(responseTimeout: .seconds(1))
    let collector = MessageCollector()
    try await transport.connect()
    let receiveTask = Task {
      for try await message in await transport.receive() {
        await collector.append(message)
      }
    }

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

    #expect(await eventually { await collector.count() >= 2 })
    let requests = await collector.snapshot()
    let internalIDs = try requests.prefix(2).map { data in
      let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      return try #require(json["id"] as? String)
    }
    #expect(Set(internalIDs).count == 2)
    var contexts: [Data] = []
    for internalID in internalIDs {
      if let body = await transport.httpRequestContext(for: .string(internalID))?.body {
        contexts.append(body)
      }
    }
    #expect(Set(contexts) == Set([numericBody, stringBody]))

    for internalID in internalIDs {
      try await transport.send(
        Data(#"{"jsonrpc":"2.0","id":"\#(internalID)","result":{}}"#.utf8)
      )
    }
    let numericResponse = await numericTask.value
    let stringResponse = await stringTask.value
    await transport.disconnect()
    receiveTask.cancel()

    let numericBodyData = try #require(numericResponse.bodyData)
    let stringBodyData = try #require(stringResponse.bodyData)
    let numericJSON = try #require(
      JSONSerialization.jsonObject(with: numericBodyData) as? [String: Any]
    )
    let stringJSON = try #require(
      JSONSerialization.jsonObject(with: stringBodyData) as? [String: Any]
    )
    #expect((numericJSON["id"] as? NSNumber)?.intValue == 1)
    #expect(stringJSON["id"] as? String == "1")
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

  @Test("publishes read and policy-controlled write tools over HTTP")
  func publishesReadAndWriteToolCatalog() async throws {
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
          "mail_send_message",
          "mail_create_draft",
          "mail_move_message",
          "mail_archive_message",
          "mail_trash_message",
          "mail_update_message",
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
