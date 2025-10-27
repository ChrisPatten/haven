import Foundation
@_spi(Generated) import OpenAPIRuntime
import HTTPTypes
@preconcurrency import HavenCore

/// ServerTransport implementation that bridges OpenAPI runtime with our NIO-based HTTP server.
///
/// This transport allows the OpenAPI-generated handlers to work with our existing
/// HTTPRequest/HTTPResponse infrastructure without replacing the entire server.
public final class OpenAPIServerTransport: ServerTransport {
    
    public init() {}
    
    /// Register an OpenAPI handler for a specific HTTP operation.
    ///
    /// This method is called by the OpenAPI runtime to register handlers generated
    /// from the OpenAPI spec. We store these handlers and will invoke them when
    /// matching requests arrive via our RouteHandler integration.
    public func register(
        _ handler: @Sendable @escaping (
            _ request: HTTPTypes.HTTPRequest,
            _ body: OpenAPIRuntime.HTTPBody?,
            _ metadata: OpenAPIRuntime.ServerRequestMetadata
        ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?),
        method: HTTPTypes.HTTPRequest.Method,
        path: String
    ) throws {
        // Store the handler for later invocation
        let operation = OperationDescriptor(
            method: method,
            path: path,
            handler: handler
        )
        operations.append(operation)
    }
    
    // MARK: - Internal routing support
    
    /// Registered OpenAPI operations
    private var operations: [OperationDescriptor] = []
    
    /// Process an incoming HTTP request through the registered OpenAPI handlers.
    ///
    /// This method is called by our RouteHandler to process requests that should
    /// be handled by OpenAPI-generated code.
    internal func handleRequest(
        _ request: HavenCore.HTTPRequest,
        context: RequestContext
    ) async -> HavenCore.HTTPResponse {
        // Find a matching operation
        guard let operation = findMatchingOperation(request) else {
            return HavenCore.HTTPResponse.notFound(message: "No OpenAPI handler found for \(request.method) \(request.path)")
        }
        
        do {
            // Convert HTTPRequest to HTTPTypes.HTTPRequest
            let (httpTypesRequest, httpBody) = try convertToHTTPTypesRequest(request)
            
            // Create metadata with path parameters
            let pathParams = extractPathParameters(from: request.path, pattern: operation.path)
            let metadata = ServerRequestMetadata(pathParameters: pathParams)
            
            // Invoke the OpenAPI handler
            let (httpTypesResponse, responseBody) = try await operation.handler(httpTypesRequest, httpBody, metadata)
            
            // Convert HTTPTypes.HTTPResponse back to HTTPResponse
            return try await convertToHTTPResponse(httpTypesResponse, body: responseBody)
            
        } catch {
            // Handle errors
            return HavenCore.HTTPResponse.internalError(message: "OpenAPI handler error: \(error.localizedDescription)")
        }
    }
    
    /// Check if this transport has a handler for the given request.
    internal func canHandle(_ request: HavenCore.HTTPRequest) -> Bool {
        return findMatchingOperation(request) != nil
    }
    
    // MARK: - Private helpers
    
    private func findMatchingOperation(_ request: HavenCore.HTTPRequest) -> OperationDescriptor? {
        let requestMethod = HTTPTypes.HTTPRequest.Method(rawValue: request.method)
        
        for operation in operations {
            if operation.method == requestMethod && pathMatches(request.path, pattern: operation.path) {
                return operation
            }
        }
        
        return nil
    }
    
    private func pathMatches(_ path: String, pattern: String) -> Bool {
        // Simple path matching that supports path parameters like {collector}
        let pathComponents = path.split(separator: "/").map(String.init)
        let patternComponents = pattern.split(separator: "/").map(String.init)
        
        guard pathComponents.count == patternComponents.count else {
            return false
        }
        
        for (pathComponent, patternComponent) in zip(pathComponents, patternComponents) {
            // Check if it's a path parameter (e.g., {collector})
            if patternComponent.hasPrefix("{") && patternComponent.hasSuffix("}") {
                // This is a path parameter, it matches any value
                continue
            } else if pathComponent != patternComponent {
                // Literal component must match exactly
                return false
            }
        }
        
        return true
    }
    
    private func extractPathParameters(from path: String, pattern: String) -> [String: String] {
        var parameters: [String: String] = [:]
        
        let pathComponents = path.split(separator: "/").map(String.init)
        let patternComponents = pattern.split(separator: "/").map(String.init)
        
        for (pathComponent, patternComponent) in zip(pathComponents, patternComponents) {
            if patternComponent.hasPrefix("{") && patternComponent.hasSuffix("}") {
                let paramName = String(patternComponent.dropFirst().dropLast())
                parameters[paramName] = pathComponent
            }
        }
        
        return parameters
    }
    
    private func convertToHTTPTypesRequest(_ request: HavenCore.HTTPRequest) throws -> (HTTPTypes.HTTPRequest, OpenAPIRuntime.HTTPBody?) {
        // Build the HTTPTypes.HTTPRequest
        var httpRequest = HTTPTypes.HTTPRequest(
            method: HTTPTypes.HTTPRequest.Method(rawValue: request.method) ?? .post,
            scheme: "http",
            authority: "localhost",
            path: request.path
        )
        
        // Add headers
        for (name, value) in request.headers {
            if let fieldName = HTTPTypes.HTTPField.Name(name) {
                httpRequest.headerFields[fieldName] = value
            }
        }
        
        // Convert body
        let body: OpenAPIRuntime.HTTPBody?
        if let bodyData = request.body {
            body = OpenAPIRuntime.HTTPBody(bodyData)
        } else {
            body = nil
        }
        
        return (httpRequest, body)
    }
    
    private func convertToHTTPResponse(
        _ response: HTTPTypes.HTTPResponse,
        body: OpenAPIRuntime.HTTPBody?
    ) async throws -> HavenCore.HTTPResponse {
        // Convert status code
        let statusCode = response.status.code
        
        // Convert headers
        var headers: [String: String] = [:]
        for field in response.headerFields {
            headers[field.name.canonicalName] = field.value
        }
        
        // Convert body
        let bodyData: Data?
        if let body = body {
            bodyData = try await Data(collecting: body, upTo: 10 * 1024 * 1024) // 10MB limit
        } else {
            bodyData = nil
        }
        
        return HavenCore.HTTPResponse(
            statusCode: Int(statusCode),
            headers: headers,
            body: bodyData
        )
    }
}

// MARK: - Supporting Types

/// Descriptor for a registered OpenAPI operation
private struct OperationDescriptor {
    let method: HTTPTypes.HTTPRequest.Method
    let path: String
    let handler: @Sendable (
        _ request: HTTPTypes.HTTPRequest,
        _ body: OpenAPIRuntime.HTTPBody?,
        _ metadata: OpenAPIRuntime.ServerRequestMetadata
    ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?)
}

// MARK: - Extensions

extension ServerRequestMetadata {
    fileprivate init(pathParameters: [String: String]) {
        // ServerRequestMetadata expects [String: Substring]
        let substringParams = pathParameters.mapValues { Substring($0) }
        self.init(pathParameters: substringParams)
    }
}

extension Data {
    /// Collect data from an HTTPBody stream
    fileprivate init(collecting body: OpenAPIRuntime.HTTPBody, upTo maxBytes: Int) async throws {
        var data = Data()
        for try await chunk in body {
            guard data.count + chunk.count <= maxBytes else {
                throw OpenAPITransportError.bodyTooLarge
            }
            data.append(contentsOf: chunk)
        }
        self = data
    }
}

// MARK: - Errors

enum OpenAPITransportError: Error, LocalizedError {
    case bodyTooLarge
    case invalidRequest(String)
    
    var errorDescription: String? {
        switch self {
        case .bodyTooLarge:
            return "Request body exceeds maximum size"
        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        }
    }
}
