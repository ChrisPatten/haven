import Foundation
@preconcurrency import HavenCore

/// RouteHandler that integrates OpenAPI-generated handlers with our existing Router.
///
/// This handler wraps an OpenAPIServerTransport and implements RouteHandler so that
/// OpenAPI operations can coexist with legacy manual routes during the transition.
public struct OpenAPIRouteHandler: RouteHandler {
    private let transport: OpenAPIServerTransport
    
    public init(transport: OpenAPIServerTransport) {
        self.transport = transport
    }
    
    /// Check if this handler can handle the request (has a matching OpenAPI operation).
    public func matches(request: HTTPRequest) -> Bool {
        return transport.canHandle(request)
    }
    
    /// Handle the request by delegating to the OpenAPI transport.
    public func handle(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        return await transport.handleRequest(request, context: context)
    }
}
