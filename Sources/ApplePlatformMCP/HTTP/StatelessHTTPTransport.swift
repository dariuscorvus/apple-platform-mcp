import Foundation
import Logging
import MCP

public actor ApplePlatformMCPStatelessHTTPTransport: Transport, HTTPContextProviding {
  public nonisolated let logger: Logger

  private enum RequestKey: Hashable, Sendable {
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

    var jsonValue: Any {
      switch self {
      case .string(let value):
        return value
      case .number(let value):
        return value
      }
    }
  }

  private struct InFlightRequest {
    let externalID: RequestKey
    let continuation: CheckedContinuation<ResponseOutcome, Never>
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
    case cancelled
    case disconnected
  }

  private let validationPipeline: any HTTPRequestValidationPipeline
  private let responseTimeout: Duration
  private let incomingStream: AsyncThrowingStream<Data, Swift.Error>
  private let incomingContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

  private var started = false
  private var terminated = false
  private var internalIDByExternalID: [RequestKey: RequestKey] = [:]
  private var inFlightByInternalID: [RequestKey: InFlightRequest] = [:]
  private var timeoutTasks: [RequestKey: Task<Void, Never>] = [:]
  private var httpRequestContexts: [RequestKey: HTTPRequest] = [:]

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
    terminateTransport()
  }

  private func terminateTransport() {
    terminated = true
    for task in timeoutTasks.values {
      task.cancel()
    }
    timeoutTasks.removeAll()
    let inFlight = inFlightByInternalID.values
    inFlightByInternalID.removeAll()
    internalIDByExternalID.removeAll()
    httpRequestContexts.removeAll()
    incomingContinuation.finish()
    for request in inFlight {
      request.continuation.resume(returning: .disconnected)
    }
  }

  public func send(_ data: Data) async throws {
    guard !terminated else {
      throw MCPError.connectionClosed
    }
    guard case .response(let internalID) = Self.classify(data),
      let request = inFlightByInternalID.removeValue(forKey: internalID)
    else {
      return
    }
    timeoutTasks.removeValue(forKey: internalID)?.cancel()
    httpRequestContexts.removeValue(forKey: internalID)
    internalIDByExternalID.removeValue(forKey: request.externalID)
    guard let externalResponse = Self.replacingTopLevelID(in: data, with: request.externalID) else {
      request.continuation.resume(returning: .disconnected)
      return
    }
    request.continuation.resume(returning: .response(externalResponse))
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
    case .notification(let method):
      if method == "notifications/cancelled" {
        if let (internalID, translated) = translateClientCancellation(body) {
          incomingContinuation.yield(translated)
          abandonRequest(
            internalID,
            outcome: .cancelled,
            reason: "MCP client cancelled request",
            sendCancellation: false
          )
        }
      } else {
        incomingContinuation.yield(body)
      }
      return .accepted()
    case .response:
      incomingContinuation.yield(body)
      return .accepted()
    case .request(let externalID, _):
      return await handleJSONRPCRequest(body, externalID: externalID, request: request)
    }
  }

  public func httpRequestContext(for id: ID) async -> HTTPRequest? {
    httpRequestContexts[RequestKey(id)]
  }

  private func handleJSONRPCRequest(
    _ body: Data,
    externalID: RequestKey,
    request: HTTPRequest
  ) async -> HTTPResponse {
    guard internalIDByExternalID[externalID] == nil else {
      return .error(
        statusCode: 409,
        .invalidRequest("A request with this JSON-RPC ID is already in flight")
      )
    }
    guard !Task.isCancelled else {
      return .error(statusCode: 499, .internalError("Client closed request"))
    }

    let internalID = RequestKey.string(UUID().uuidString)
    guard let internalBody = Self.replacingTopLevelID(in: body, with: internalID) else {
      return .error(statusCode: 400, .parseError("Invalid JSON-RPC message"))
    }
    internalIDByExternalID[externalID] = internalID
    httpRequestContexts[internalID] = request

    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<ResponseOutcome, Never>) in
        inFlightByInternalID[internalID] = InFlightRequest(
          externalID: externalID,
          continuation: continuation
        )
        timeoutTasks[internalID] = Task { [weak self, responseTimeout] in
          do {
            try await Task.sleep(for: responseTimeout)
          } catch {
            return
          }
          await self?.expireRequest(internalID)
        }
        incomingContinuation.yield(internalBody)
      }
    } onCancel: {
      Task { [weak self] in
        await self?.cancelRequest(internalID)
      }
    }

    switch outcome {
    case .response(let data):
      return .data(data, headers: [HTTPHeaderName.contentType: "application/json"])
    case .timedOut:
      return .error(statusCode: 504, .internalError("Request timed out"))
    case .cancelled:
      return .error(statusCode: 499, .internalError("Client closed request"))
    case .disconnected:
      return .error(statusCode: 503, .internalError("Service unavailable"))
    }
  }

  private func expireRequest(_ internalID: RequestKey) {
    abandonRequest(
      internalID,
      outcome: .timedOut,
      reason: "HTTP request timed out"
    )
  }

  private func cancelRequest(_ internalID: RequestKey) {
    abandonRequest(
      internalID,
      outcome: .cancelled,
      reason: "HTTP client disconnected"
    )
  }

  private func abandonRequest(
    _ internalID: RequestKey,
    outcome: ResponseOutcome,
    reason: String,
    sendCancellation: Bool = true
  ) {
    guard let request = inFlightByInternalID.removeValue(forKey: internalID) else { return }
    timeoutTasks.removeValue(forKey: internalID)?.cancel()
    httpRequestContexts.removeValue(forKey: internalID)
    internalIDByExternalID.removeValue(forKey: request.externalID)
    if sendCancellation,
      let cancellation = Self.cancellationNotification(for: internalID, reason: reason)
    {
      incomingContinuation.yield(cancellation)
    }
    request.continuation.resume(returning: outcome)
  }

  private func translateClientCancellation(_ data: Data) -> (RequestKey, Data)? {
    guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      var params = json["params"] as? [String: Any],
      let externalID = Self.normalizedID(params["requestId"]),
      let internalID = internalIDByExternalID[externalID]
    else {
      return nil
    }
    params["requestId"] = internalID.jsonValue
    json["params"] = params
    guard let translated = try? JSONSerialization.data(withJSONObject: json) else {
      return nil
    }
    return (internalID, translated)
  }

  private static func cancellationNotification(for id: RequestKey, reason: String) -> Data? {
    try? JSONSerialization.data(withJSONObject: [
      "jsonrpc": "2.0",
      "method": "notifications/cancelled",
      "params": [
        "requestId": id.jsonValue,
        "reason": reason,
      ],
    ])
  }

  private static func replacingTopLevelID(in data: Data, with id: RequestKey) -> Data? {
    guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    json["id"] = id.jsonValue
    return try? JSONSerialization.data(withJSONObject: json)
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
