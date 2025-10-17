import Core
import Foundation
import Logging
@preconcurrency import NIO
@preconcurrency import NIOHTTP1

public final class HostHTTPServer: @unchecked Sendable {
    private let logger = Logger(label: "HostAgent.HostHTTPServer")
    private let group: EventLoopGroup
    private var channel: Channel?
    private let router: HostHTTPRouter

    public init(
        group: EventLoopGroup,
        router: HostHTTPRouter
    ) {
        self.group = group
        self.router = router
    }

    public func start(on port: Int) async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(HTTPRequestHandler(router: self.router))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        if let localAddress = channel?.localAddress {
            logger.info("HTTP server started", metadata: ["address": "\(localAddress)"])
        } else {
            logger.info("HTTP server started on port \(port)")
        }
    }

    public func shutdown() async throws {
        try await channel?.close().get()
    }
}

final class HTTPRequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private enum State {
        case idle
        case head(HTTPRequestHead)
        case body(HTTPRequestHead, ByteBuffer)
    }

    private var state: State = .idle
    private let router: HostHTTPRouter

    init(router: HostHTTPRouter) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            state = .head(head)
        case .body(var body):
            switch state {
            case .head(let head):
                state = .body(head, body)
            case .body(let head, var existingBody):
                existingBody.writeBuffer(&body)
                state = .body(head, existingBody)
            case .idle:
                break
            }
        case .end:
            handleRequest(context: context)
            state = .idle
        }
    }

    private func handleRequest(context: ChannelHandlerContext) {
        guard case .head(let head) = state else {
            writeResponse(context: context, response: .text("invalid request", status: .badRequest))
            return
        }

        var bodyData = Data()
        if case .body(_, let bodyBuffer) = state {
            var buffer = bodyBuffer
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                bodyData = Data(bytes)
            }
        }

        let query = Self.parseQuery(from: head.uri)
        let request = HostHTTPRequest(
            method: head.method,
            uri: head.uri,
            path: URL(string: head.uri)?.path ?? head.uri.components(separatedBy: "?").first ?? head.uri,
            query: query,
            headers: head.headers,
            body: bodyData,
            remoteAddress: context.remoteAddress?.description
        )

        let router = self.router
        let eventLoop = context.eventLoop
        Task {
            let response = await router.handle(request)
            eventLoop.execute {
                self.writeResponse(context: context, response: response)
            }
        }
    }

    private func writeResponse(context: ChannelHandlerContext, response: HostHTTPResponse) {
        var headers = response.headers
        headers.add(name: "Connection", value: "close")

        let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: response.status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        if !response.body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }

        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func send(response: HostHTTPResponse, context: ChannelHandlerContext) async {
        context.eventLoop.execute {
            self.writeResponse(context: context, response: response)
        }
    }

    static func parseQuery(from uri: String) -> [String: String] {
        guard let url = URLComponents(string: uri), let items = url.queryItems else { return [:] }
        var result: [String: String] = [:]
        for item in items {
            if let value = item.value {
                result[item.name] = value
            }
        }
        return result
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        writeResponse(context: context, response: .text("internal server error", status: .internalServerError))
        context.close(promise: nil)
    }
}
