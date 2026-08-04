import Foundation
import MCP

private actor ConcurrentMCPRequestGate {
  private let maximum: Int
  private var active = 0

  init(maximum: Int) {
    self.maximum = max(1, maximum)
  }

  func acquire() -> Bool {
    guard active < maximum else { return false }
    active += 1
    return true
  }

  func release() {
    active -= 1
  }
}

public struct ApplePlatformMCPHTTPResponse: Sendable {
  public let statusCode: Int
  public let headers: [String: String]
  public let bodyData: Data?

  public init(
    statusCode: Int,
    headers: [String: String] = [:],
    bodyData: Data? = nil
  ) {
    self.statusCode = statusCode
    self.headers = headers
    self.bodyData = bodyData
  }

  fileprivate init(mcpResponse: HTTPResponse) {
    switch mcpResponse {
    case .stream:
      self.init(statusCode: 500)
    default:
      self.init(
        statusCode: mcpResponse.statusCode,
        headers: mcpResponse.headers,
        bodyData: mcpResponse.bodyData
      )
    }
  }
}

public struct ApplePlatformMCPHTTPRouter: Sendable {
  private struct StatusPayload: Encodable {
    let status: String
  }

  public typealias MCPHandler = @Sendable (HTTPRequest) async -> HTTPResponse
  public typealias ReadinessProbe = @Sendable () async -> Bool

  private let mcpHandler: MCPHandler
  private let readinessProbe: ReadinessProbe
  private let requestGate: ConcurrentMCPRequestGate

  public init(
    maximumConcurrentMCPRequests: Int = 4,
    mcpHandler: @escaping MCPHandler,
    readinessProbe: @escaping ReadinessProbe
  ) {
    self.mcpHandler = mcpHandler
    self.readinessProbe = readinessProbe
    self.requestGate = ConcurrentMCPRequestGate(
      maximum: maximumConcurrentMCPRequests
    )
  }

  public func handle(_ request: HTTPRequest) async -> ApplePlatformMCPHTTPResponse {
    if request.method.uppercased() == "GET", request.path == "/health/live" {
      return Self.statusResponse(statusCode: 200, status: "live")
    }

    if request.method.uppercased() == "GET", request.path == "/health/ready" {
      let isReady = await readinessProbe()
      return Self.statusResponse(
        statusCode: isReady ? 200 : 503,
        status: isReady ? "ready" : "not_ready"
      )
    }

    if request.path == "/mcp" {
      guard await requestGate.acquire() else {
        return Self.statusResponse(
          statusCode: 429,
          status: "too_many_requests"
        )
      }
      let response = ApplePlatformMCPHTTPResponse(
        mcpResponse: await mcpHandler(request)
      )
      await requestGate.release()
      return response
    }

    return Self.statusResponse(statusCode: 404, status: "not_found")
  }

  private static func statusResponse(
    statusCode: Int,
    status: String
  ) -> ApplePlatformMCPHTTPResponse {
    let body =
      (try? JSONEncoder().encode(StatusPayload(status: status)))
      ?? Data(#"{"status":"internal_error"}"#.utf8)
    return ApplePlatformMCPHTTPResponse(
      statusCode: statusCode,
      headers: [
        "Cache-Control": "no-store",
        "Content-Type": "application/json",
      ],
      bodyData: body
    )
  }
}
