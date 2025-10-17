import Foundation
import HavenCore

/// HTTP request router
public struct Router {
    private let logger = HavenLogger(category: "router")
    private let handlers: [RouteHandler]
    
    public init(handlers: [RouteHandler]) {
        self.handlers = handlers
    }
    
    public func route(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        // Find matching handler
        for handler in handlers {
            if handler.matches(request: request) {
                return await handler.handle(request: request, context: context)
            }
        }
        
        // No handler found
        logger.warning("No route found", metadata: ["path": request.path, "method": request.method])
        
        return HTTPResponse(
            statusCode: 404,
            headers: ["Content-Type": "application/json"],
            body: #"{"error":"Not Found"}"#.data(using: .utf8)
        )
    }
}

/// Protocol for route handlers
public protocol RouteHandler {
    func matches(request: HTTPRequest) -> Bool
    func handle(request: HTTPRequest, context: RequestContext) async -> HTTPResponse
}

/// Simple pattern-based route handler
public struct PatternRouteHandler: RouteHandler {
    let method: String
    let pattern: String
    let handler: (HTTPRequest, RequestContext) async -> HTTPResponse
    
    public init(method: String, pattern: String, handler: @escaping (HTTPRequest, RequestContext) async -> HTTPResponse) {
        self.method = method
        self.pattern = pattern
        self.handler = handler
    }
    
    public func matches(request: HTTPRequest) -> Bool {
        guard request.method == method else { return false }
        
        // Simple path matching (exact or prefix)
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return request.path.hasPrefix(prefix)
        } else {
            return request.path == pattern
        }
    }
    
    public func handle(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        return await handler(request, context)
    }
}
