import MCP

public actor ApplePlatformMCPStreamableHTTPRuntime {
  private let server: Server
  private let transport: ApplePlatformMCPStatelessHTTPTransport
  public nonisolated let router: ApplePlatformMCPHTTPRouter
  private var started = false

  public init(
    server: Server,
    readinessProbe: @escaping ApplePlatformMCPHTTPRouter.ReadinessProbe
  ) {
    let transport = ApplePlatformMCPStatelessHTTPTransport()
    self.server = server
    self.transport = transport
    self.router = ApplePlatformMCPHTTPRouter(
      mcpHandler: { request in
        await transport.handleRequest(request)
      },
      readinessProbe: readinessProbe
    )
  }

  public func start() async throws {
    guard !started else {
      throw MailError.invalidInput("Streamable HTTP runtime is already started.")
    }
    started = true
    do {
      try await server.start(transport: transport)
    } catch {
      started = false
      throw error
    }
  }

  public func handle(_ request: HTTPRequest) async -> ApplePlatformMCPHTTPResponse {
    guard started else {
      return ApplePlatformMCPHTTPResponse(statusCode: 503)
    }
    return await router.handle(request)
  }

  public func stop() async {
    guard started else { return }
    started = false
    await server.stop()
  }
}
