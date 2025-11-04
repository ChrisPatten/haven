import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
@preconcurrency import HavenCore

/// SwiftNIO-based HTTP server for Haven Host Agent
public final class HavenHTTPServer: @unchecked Sendable {
    private let config: HavenConfig
    private let router: Router
    private let logger: HavenLogger
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    
    public init(config: HavenConfig, router: Router) throws {
        self.config = config
        self.router = router
        self.logger = HavenLogger(category: "http-server")
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }
    
    deinit {
        // Best-effort synchronous shutdown for deinit (can't await here)
        try? group.syncShutdownGracefully()
    }
    
    public func start() async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(HTTPHandler(router: self.router, config: self.config))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        
        do {
            self.channel = try await bootstrap.bind(host: "127.0.0.1", port: config.service.port).get()
            
            logger.info("🚀 Haven Host Agent started", metadata: [
                "host": "127.0.0.1",
                "port": config.service.port,
                "auth_header": config.service.auth.header
            ])
            
            // Wait for server to close
            try await channel?.closeFuture.get()
        } catch {
            logger.error("Failed to start server", error: error)
            throw error
        }
    }
    
    public func stop() async throws {
        logger.info("Stopping HTTP server...")
        try await channel?.close()
        // Use async shutdown to avoid blocking from an async context
        try await group.shutdownGracefully()
    }
}

// MARK: - HTTP Request Handler

final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    
    private let router: Router
    private let config: HavenConfig
    private let logger = HavenLogger(category: "http-handler")
    
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?
    private var context: RequestContext?
    
    init(router: Router, config: HavenConfig) {
        self.router = router
        self.config = config
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        
        switch part {
        case .head(let head):
            self.requestHead = head
            self.requestBody = nil
            self.context = RequestContext()
            
        case .body(var buffer):
            if requestBody == nil {
                requestBody = buffer
            } else {
                requestBody?.writeBuffer(&buffer)
            }
            
        case .end:
            guard let head = requestHead,
                  let reqContext = self.context else {
                return
            }
            
            // Parse query parameters from URI
            let pathAndQuery = head.uri.split(separator: "?", maxSplits: 1)
            let path = String(pathAndQuery.first ?? "")
            let queryString = pathAndQuery.count > 1 ? String(pathAndQuery[1]) : ""
            let queryParams = HavenCore.URLUtils.parseQueryString(queryString)
            
            // Build request
            let request = HTTPRequest(
                method: head.method.rawValue,
                path: path,
                queryParameters: queryParams,
                headers: Dictionary(uniqueKeysWithValues: head.headers.map { ($0.name.lowercased(), $0.value) }),
                body: requestBody.map { buffer in
                    var data = Data()
                    data.reserveCapacity(buffer.readableBytes)
                    data.append(contentsOf: buffer.readableBytesView)
                    return data
                }
            )
            
            // Process request asynchronously, but send response on the EventLoop.
            // Convert the non-Sendable `context` into an opaque pointer (raw) so
            // we don't capture the non-Sendable type in a @Sendable closure.
            let eventLoop = context.eventLoop
            let ctxRaw = Int(bitPattern: Unmanaged.passUnretained(context).toOpaque())
            let headVersion = head.version

            Task {
                let response = await processRequest(request, context: reqContext)

                // Execute the response sending on the EventLoop. Reconstruct the
                // ChannelHandlerContext from the opaque pointer inside the eventLoop
                // closure to avoid capturing it into the @Sendable closure.
                eventLoop.execute {
                    let ptr = UnsafeRawPointer(bitPattern: ctxRaw)!
                    let ctx = Unmanaged<ChannelHandlerContext>.fromOpaque(ptr).takeUnretainedValue()
                    self.sendResponse(context: ctx, response: response, version: headVersion)
                }
            }
            
            // Reset state
            self.requestHead = nil
            self.requestBody = nil
        }
    }
    
    private func processRequest(_ request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        logger.debug("Request", metadata: [
            "method": request.method,
            "path": request.path,
            "request_id": context.requestId
        ])
        
        // Auth check
        let authHeader = config.service.auth.header.lowercased()
        guard let token = request.headers[authHeader],
              constantTimeCompare(token, config.service.auth.secret) else {
            await MetricsCollector.shared.incrementCounter("http_requests_total", labels: ["status": "401"])
            return HTTPResponse(
                statusCode: 401,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"Unauthorized"}"#.data(using: .utf8)
            )
        }
        
        // Route request
        let response = await router.route(request: request, context: context)
        
        // Log response
        let elapsed = context.elapsedMs()
        logger.info("Response", metadata: [
            "method": request.method,
            "path": request.path,
            "status": response.statusCode,
            "elapsed_ms": elapsed,
            "request_id": context.requestId
        ])
        
        await MetricsCollector.shared.incrementCounter("http_requests_total", labels: [
            "method": request.method,
            "path": request.path,
            "status": String(response.statusCode)
        ])
        await MetricsCollector.shared.recordHistogram("http_request_duration_ms", value: Double(elapsed), labels: [
            "path": request.path
        ])
        
        return response
    }
    
    private func sendResponse(context: ChannelHandlerContext, response: HTTPResponse, version: HTTPVersion) {
        // Send headers
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.add(name: name, value: value)
        }
        
        let responseHead = HTTPResponseHead(
            version: version,
            status: HTTPResponseStatus(statusCode: response.statusCode),
            headers: headers
        )
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        
        // Send body if present
        if let body = response.body {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        
        // Send end
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
    
    private func constantTimeCompare(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count else { return false }
        
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        
        var result = 0
        for i in 0..<aBytes.count {
            result |= Int(aBytes[i] ^ bBytes[i])
        }
        
        return result == 0
    }
}


