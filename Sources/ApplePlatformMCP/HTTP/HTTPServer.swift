import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

public actor ApplePlatformMCPHTTPServer {
  private let host: String
  private let port: Int
  private let maxRequestBodyBytes: Int
  private let requestReadTimeoutSeconds: Int
  private let router: ApplePlatformMCPHTTPRouter
  private let eventLoopGroup: MultiThreadedEventLoopGroup
  private let connectionGate = ApplePlatformMCPConnectionGate(maximumConnections: 32)
  private var channel: Channel?
  private var terminated = false

  public init(
    host: String,
    port: Int,
    maxRequestBodyBytes: Int = 1_048_576,
    requestReadTimeoutSeconds: Int = 15,
    router: ApplePlatformMCPHTTPRouter
  ) {
    self.host = host
    self.port = port
    self.maxRequestBodyBytes = maxRequestBodyBytes
    self.requestReadTimeoutSeconds = requestReadTimeoutSeconds
    self.router = router
    self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  }

  @discardableResult
  public func start() async throws -> Int {
    guard host == "127.0.0.1" else {
      throw MailError.invalidInput(
        "Streamable HTTP must bind to 127.0.0.1. Non-loopback listeners are disabled."
      )
    }
    guard (0...65_535).contains(port), maxRequestBodyBytes > 0, requestReadTimeoutSeconds > 0 else {
      throw MailError.invalidInput("The HTTP listener configuration is invalid.")
    }
    guard !terminated else {
      throw MailError.invalidInput("The HTTP listener cannot be restarted after shutdown.")
    }
    guard channel == nil else {
      throw MailError.invalidInput("The HTTP listener is already running.")
    }

    let router = self.router
    let maxRequestBodyBytes = self.maxRequestBodyBytes
    let requestReadTimeout = TimeAmount.seconds(Int64(requestReadTimeoutSeconds))
    let connectionLifetime = TimeAmount.seconds(Int64(requestReadTimeoutSeconds * 3))
    let connectionGate = self.connectionGate
    let decoderLimits: NIOHTTPDecoderLimitConfiguration = {
      var limits = NIOHTTPDecoderLimitConfiguration()
      limits.maxHeaderFieldSize = 8_192
      limits.maxHeaderListSize = 16_384
      limits.maxHeaderFieldCount = 64
      return limits
    }()
    let bootstrap = ServerBootstrap(group: eventLoopGroup)
      .serverChannelOption(ChannelOptions.backlog, value: 128)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        guard connectionGate.acquire() else {
          return channel.close()
        }
        return channel.pipeline.addHandler(
          ApplePlatformMCPConnectionLeaseHandler(gate: connectionGate)
        ).flatMap {
          channel.pipeline.addHandler(
            ApplePlatformMCPConnectionLifetimeHandler(timeout: connectionLifetime)
          )
        }.flatMap {
          channel.pipeline.configureHTTPServerPipeline(
            withPipeliningAssistance: false,
            withErrorHandling: true,
            withOutboundHeaderValidation: true,
            withDecoderLimitConfiguration: decoderLimits
          ).flatMap {
            channel.pipeline.addHandler(
              ApplePlatformMCPNIOHTTPHandler(
                router: router,
                maxRequestBodyBytes: maxRequestBodyBytes,
                requestReadTimeout: requestReadTimeout
              )
            )
          }
        }
      }
      .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

    let channel = try await bootstrap.bind(host: host, port: port).get()
    self.channel = channel
    guard let boundPort = channel.localAddress?.port else {
      try? await channel.close()
      self.channel = nil
      throw MailError.invalidInput("The HTTP listener did not report its bound port.")
    }
    return boundPort
  }

  public func waitUntilClosed() async throws {
    guard let channel else { return }
    try await channel.closeFuture.get()
  }

  public func stop() async {
    guard !terminated else { return }
    terminated = true
    if let channel {
      try? await channel.close()
      self.channel = nil
    }
    try? await eventLoopGroup.shutdownGracefully()
  }
}

private final class ApplePlatformMCPConnectionGate: @unchecked Sendable {
  private let maximumConnections: Int
  private let lock = NSLock()
  private var activeConnections = 0

  init(maximumConnections: Int) {
    self.maximumConnections = maximumConnections
  }

  func acquire() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard activeConnections < maximumConnections else { return false }
    activeConnections += 1
    return true
  }

  func release() {
    lock.lock()
    activeConnections = max(0, activeConnections - 1)
    lock.unlock()
  }
}

private final class ApplePlatformMCPConnectionLeaseHandler: ChannelInboundHandler,
  @unchecked Sendable
{
  typealias InboundIn = NIOAny
  typealias InboundOut = NIOAny

  private let gate: ApplePlatformMCPConnectionGate
  private var released = false

  init(gate: ApplePlatformMCPConnectionGate) {
    self.gate = gate
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    guard !released else { return }
    released = true
    gate.release()
  }
}

private final class ApplePlatformMCPConnectionLifetimeHandler: ChannelInboundHandler,
  @unchecked Sendable
{
  typealias InboundIn = NIOAny
  typealias InboundOut = NIOAny

  private let timeout: TimeAmount
  private var timeoutTask: Scheduled<Void>?

  init(timeout: TimeAmount) {
    self.timeout = timeout
  }

  func handlerAdded(context: ChannelHandlerContext) {
    scheduleTimeout(context: context)
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    timeoutTask?.cancel()
    timeoutTask = nil
  }

  private func scheduleTimeout(context: ChannelHandlerContext) {
    timeoutTask?.cancel()
    let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
    timeoutTask = context.eventLoop.scheduleTask(in: timeout) {
      loopBoundContext.value.close(promise: nil)
    }
  }
}

private final class ApplePlatformMCPNIOHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private struct RequestState {
    let head: HTTPRequestHead
    var bodyBuffer: ByteBuffer
    let timeoutTask: Scheduled<Void>
  }

  private let router: ApplePlatformMCPHTTPRouter
  private let maxRequestBodyBytes: Int
  private let requestReadTimeout: TimeAmount
  private var requestState: RequestState?
  private var responseTask: Task<Void, Never>?

  init(
    router: ApplePlatformMCPHTTPRouter,
    maxRequestBodyBytes: Int,
    requestReadTimeout: TimeAmount
  ) {
    self.router = router
    self.maxRequestBodyBytes = maxRequestBodyBytes
    self.requestReadTimeout = requestReadTimeout
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      guard responseTask == nil else {
        responseTask?.cancel()
        responseTask = nil
        context.close(promise: nil)
        return
      }
      if let rejection = authorityRejection(
        for: head,
        boundPort: context.channel.localAddress?.port
      ) {
        rejectAndClose(rejection, version: head.version, context: context)
        return
      }

      let contentLengths = head.headers["Content-Length"]
      let contentLength = contentLengths.first.flatMap(Int.init)
      if contentLengths.count > 1
        || (contentLengths.first != nil && contentLength == nil)
        || contentLength.map({ $0 < 0 }) == true
      {
        rejectAndClose(
          ApplePlatformMCPHTTPResponse(
            statusCode: 400,
            headers: ["Content-Type": "application/json"],
            bodyData: Data(#"{"status":"invalid_request"}"#.utf8)
          ),
          version: head.version,
          context: context
        )
        return
      }
      if contentLength.map({ $0 > maxRequestBodyBytes }) == true {
        rejectAndClose(requestTooLargeResponse(), version: head.version, context: context)
        return
      }

      let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
      let timeoutTask = context.eventLoop.scheduleTask(in: requestReadTimeout) { [weak self] in
        guard let self, self.requestState != nil else { return }
        self.requestState = nil
        self.rejectAndClose(
          ApplePlatformMCPHTTPResponse(
            statusCode: 408,
            headers: ["Content-Type": "application/json"],
            bodyData: Data(#"{"status":"request_timeout"}"#.utf8)
          ),
          version: head.version,
          context: loopBoundContext.value
        )
      }
      requestState = RequestState(
        head: head,
        bodyBuffer: context.channel.allocator.buffer(capacity: 0),
        timeoutTask: timeoutTask
      )

    case .body(var buffer):
      guard var state = requestState else { return }
      if state.bodyBuffer.readableBytes + buffer.readableBytes > maxRequestBodyBytes {
        state.timeoutTask.cancel()
        requestState = nil
        rejectAndClose(requestTooLargeResponse(), version: state.head.version, context: context)
        return
      } else {
        state.bodyBuffer.writeBuffer(&buffer)
      }
      requestState = state

    case .end:
      guard let state = requestState else { return }
      state.timeoutTask.cancel()
      requestState = nil
      let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
      let eventLoop = context.eventLoop
      let task = Task<Void, Never> { [weak self] in
        guard let self else { return }
        await self.handleRequest(
          state,
          context: loopBoundContext,
          eventLoop: eventLoop
        )
      }
      responseTask = task
      context.channel.closeFuture.whenComplete { _ in
        task.cancel()
      }
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    responseTask?.cancel()
    responseTask = nil
    requestState?.timeoutTask.cancel()
    requestState = nil
    context.close(promise: nil)
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    responseTask?.cancel()
    responseTask = nil
    requestState?.timeoutTask.cancel()
    requestState = nil
  }

  func channelInactive(context: ChannelHandlerContext) {
    responseTask?.cancel()
    responseTask = nil
    requestState?.timeoutTask.cancel()
    requestState = nil
    context.fireChannelInactive()
  }

  private func authorityRejection(
    for head: HTTPRequestHead,
    boundPort: Int?
  ) -> ApplePlatformMCPHTTPResponse? {
    guard let boundPort else {
      return authorityError(statusCode: 421)
    }
    let allowedHost = "127.0.0.1:\(boundPort)"
    let hostValues = head.headers["Host"]
    guard hostValues.count == 1, hostValues[0].lowercased() == allowedHost else {
      return authorityError(statusCode: 421)
    }

    let originValues = head.headers["Origin"]
    guard originValues.count <= 1 else {
      return authorityError(statusCode: 403)
    }
    if let origin = originValues.first,
      origin.lowercased() != "http://\(allowedHost)"
    {
      return authorityError(statusCode: 403)
    }
    return nil
  }

  private func authorityError(statusCode: Int) -> ApplePlatformMCPHTTPResponse {
    ApplePlatformMCPHTTPResponse(
      statusCode: statusCode,
      headers: ["Content-Type": "application/json"],
      bodyData: Data(#"{"status":"invalid_authority"}"#.utf8)
    )
  }

  private func requestTooLargeResponse() -> ApplePlatformMCPHTTPResponse {
    ApplePlatformMCPHTTPResponse(
      statusCode: 413,
      headers: ["Content-Type": "application/json"],
      bodyData: Data(#"{"status":"request_too_large"}"#.utf8)
    )
  }

  private func rejectAndClose(
    _ response: ApplePlatformMCPHTTPResponse,
    version: HTTPVersion,
    context: ChannelHandlerContext
  ) {
    var head = HTTPResponseHead(
      version: version,
      status: HTTPResponseStatus(statusCode: response.statusCode)
    )
    for (name, value) in response.headers {
      head.headers.replaceOrAdd(name: name, value: value)
    }
    head.headers.replaceOrAdd(name: "Content-Length", value: String(response.bodyData?.count ?? 0))
    head.headers.replaceOrAdd(name: "Connection", value: "close")
    context.write(wrapOutboundOut(.head(head)), promise: nil)
    if let body = response.bodyData {
      var buffer = context.channel.allocator.buffer(capacity: body.count)
      buffer.writeBytes(body)
      context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }
    let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
      loopBoundContext.value.close(promise: nil)
    }
  }

  private func handleRequest(
    _ state: RequestState,
    context: NIOLoopBound<ChannelHandlerContext>,
    eventLoop: any EventLoop
  ) async {
    var headers: [String: String] = [:]
    for (name, value) in state.head.headers {
      if let existing = headers[name] {
        headers[name] = existing + ", " + value
      } else {
        headers[name] = value
      }
    }

    let body: Data?
    if state.bodyBuffer.readableBytes > 0,
      let bytes = state.bodyBuffer.getBytes(
        at: state.bodyBuffer.readerIndex,
        length: state.bodyBuffer.readableBytes
      )
    {
      body = Data(bytes)
    } else {
      body = nil
    }

    let path = String(
      state.head.uri.split(separator: "?", maxSplits: 1).first
        ?? Substring(state.head.uri)
    )
    let request = HTTPRequest(
      method: state.head.method.rawValue,
      headers: headers,
      body: body,
      path: path
    )
    let response = await router.handle(request)
    write(
      response,
      version: state.head.version,
      context: context,
      eventLoop: eventLoop
    )
  }

  private func write(
    _ response: ApplePlatformMCPHTTPResponse,
    version: HTTPVersion,
    context: NIOLoopBound<ChannelHandlerContext>,
    eventLoop: any EventLoop
  ) {
    let body = response.bodyData
    let statusCode = response.statusCode
    let headers = response.headers
    eventLoop.execute {
      let context = context.value
      guard context.channel.isActive else { return }
      var head = HTTPResponseHead(
        version: version,
        status: HTTPResponseStatus(statusCode: statusCode)
      )
      for (name, value) in headers {
        head.headers.replaceOrAdd(name: name, value: value)
      }
      head.headers.replaceOrAdd(
        name: "Content-Length",
        value: String(body?.count ?? 0)
      )
      head.headers.replaceOrAdd(name: "Connection", value: "close")

      context.write(self.wrapOutboundOut(.head(head)), promise: nil)
      if let body {
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(
          self.wrapOutboundOut(.body(.byteBuffer(buffer))),
          promise: nil
        )
      }
      context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
      context.close(promise: nil)
    }
  }
}
