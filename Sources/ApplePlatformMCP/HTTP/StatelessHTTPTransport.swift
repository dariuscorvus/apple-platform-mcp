import Foundation
import Logging
import MCP

public actor ApplePlatformMCPStatelessHTTPTransport: Transport, HTTPContextProviding {
  public nonisolated let logger: Logger

  private enum RequestKey: Hashable {
    case string(String)
    case number(Int)

    init(_ id: ID) {
      switch id {
      case .string(let value):
        self = .string(value)
      case .number(let value):
        self = .number(value)
      }
    }
  }

  private enum MessageKind {
    case request(id: RequestKey, method: String)
    case notification(method: String)
    case response(id: RequestKey)

    var isInitializeRequest: Bool {
      if case .request(_, let method) = self {
        return method == "initialize"
      }
      return false
    }
  }

  private enum ResponseOutcome {
    case response(Data)
    case timedOut
    case disconnected
  }

  private let validationPipeline: any HTTPRequestValidationPipeline
  private let responseTimeout: Duration
  private let incomingStream: AsyncThrowingStream<Data, Swift.Error>
  private let incomingContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

  private var started = false
  private var terminated = false
  private var responseWaiters: [RequestKey: CheckedContinuation<ResponseOutcome, Never>] = [:]
  private var timeoutTasks: [RequestKey: Task<Void, Never>] = [:]
  private var httpRequestContexts: [RequestKey: HTTPRequest] = [:]
  private var timedOutRequestIDs: Set<RequestKey> = []

  public init(
    responseTimeout: Duration = .seconds(30),
    validationPipeline: (any HTTPRequestValidationPipeline)? = nil
  ) {
    self.responseTimeout = responseTimeout
    self.validationPipeline =
      validationPipeline
      ?? StandardValidationPipeline(validators: [
        OriginValidator.localhost(),
        AcceptHeaderValidator(mode: .jsonOnly),
        ContentTypeValidator(),
        ProtocolVersionValidator(),
      ])
    self.logger = Logger(
      label: "apple-platform-mcp.transport.http.stateless",
      factory: { _ in SwiftLogNoOpLogHandler() }
    )
    let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
    self.incomingStream = stream
    self.incomingContinuation = continuation
  }

  public func connect() async throws {
    guard !started else {
      throw MCPError.internalError("Transport already started")
    }
    started = true
  }

  public func disconnect() async {
    guard !terminated else { return }
    terminated = true
    for task in timeoutTasks.values {
      task.cancel()
    }
    timeoutTasks.removeAll()
    let waiters = responseWaiters
    responseWaiters.removeAll()
    httpRequestContexts.removeAll()
    timedOutRequestIDs.removeAll()
    incomingContinuation.finish()
    for continuation in waiters.values {
      continuation.resume(returning: .disconnected)
    }
  }

  public func send(_ data: Data) async throws {
    guard !terminated else {
      throw MCPError.connectionClosed
    }
    guard case .response(let id) = Self.classify(data) else {
      return
    }
    if timedOutRequestIDs.remove(id) != nil {
      return
    }
    guard let continuation = responseWaiters.removeValue(forKey: id) else {
      return
    }
    timeoutTasks.removeValue(forKey: id)?.cancel()
    httpRequestContexts.removeValue(forKey: id)
    continuation.resume(returning: .response(data))
  }

  public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
    incomingStream
  }

  public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
    guard started, !terminated else {
      return .error(statusCode: 503, .internalError("Service unavailable"))
    }
    guard request.method.uppercased() == "POST" else {
      return .error(
        statusCode: 405,
        .invalidRequest("Method Not Allowed"),
        extraHeaders: [HTTPHeaderName.allow: "POST"]
      )
    }
    guard let body = request.body, !body.isEmpty else {
      return .error(statusCode: 400, .parseError("Empty request body"))
    }
    guard let kind = Self.classify(body) else {
      return .error(statusCode: 400, .parseError("Invalid JSON-RPC message"))
    }

    let context = HTTPValidationContext(
      httpMethod: "POST",
      isInitializationRequest: kind.isInitializeRequest,
      supportedProtocolVersions: Version.supported
    )
    if let errorResponse = validationPipeline.validate(request, context: context) {
      return errorResponse
    }

    switch kind {
    case .notification, .response:
      incomingContinuation.yield(body)
      return .accepted()
    case .request(let id, _):
      return await handleJSONRPCRequest(body, id: id, request: request)
    }
  }

  public func httpRequestContext(for id: ID) async -> HTTPRequest? {
    httpRequestContexts[RequestKey(id)]
  }

  private func handleJSONRPCRequest(
    _ body: Data,
    id: RequestKey,
    request: HTTPRequest
  ) async -> HTTPResponse {
    guard responseWaiters[id] == nil, !timedOutRequestIDs.contains(id) else {
      return .error(
        statusCode: 409,
        .invalidRequest("A request with this JSON-RPC ID is already in flight")
      )
    }

    httpRequestContexts[id] = request
    let outcome = await withCheckedContinuation {
      (continuation: CheckedContinuation<ResponseOutcome, Never>) in
      responseWaiters[id] = continuation
      timeoutTasks[id] = Task { [weak self, responseTimeout] in
        try? await Task.sleep(for: responseTimeout)
        guard !Task.isCancelled else { return }
        await self?.expireRequest(id)
      }
      incomingContinuation.yield(body)
    }

    switch outcome {
    case .response(let data):
      return .data(data, headers: [HTTPHeaderName.contentType: "application/json"])
    case .timedOut:
      return .error(statusCode: 504, .internalError("Request timed out"))
    case .disconnected:
      return .error(statusCode: 503, .internalError("Service unavailable"))
    }
  }

  private func expireRequest(_ id: RequestKey) {
    guard let continuation = responseWaiters.removeValue(forKey: id) else { return }
    timeoutTasks.removeValue(forKey: id)?.cancel()
    httpRequestContexts.removeValue(forKey: id)
    timedOutRequestIDs.insert(id)
    continuation.resume(returning: .timedOut)
  }

  private static func classify(_ data: Data) -> MessageKind? {
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let json = object as? [String: Any],
      json["jsonrpc"] as? String == "2.0"
    else {
      return nil
    }

    let id = normalizedID(json["id"])
    if let method = json["method"] as? String {
      if let id {
        return .request(id: id, method: method)
      }
      return .notification(method: method)
    }
    if json["result"] != nil || json["error"] != nil, let id {
      return .response(id: id)
    }
    return nil
  }

  private static func normalizedID(_ value: Any?) -> RequestKey? {
    if let string = value as? String {
      return .string(string)
    }
    if let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      let integer = Int(number.stringValue)
    {
      return .number(integer)
    }
    return nil
  }
}
