import Foundation

/// Authentication middleware for validating x-auth header
public struct AuthMiddleware {
    private let headerName: String
    private let secret: String
    private let logger = HavenLogger(category: "auth")
    
    public init(headerName: String, secret: String) {
        self.headerName = headerName
        self.secret = secret
    }
    
    public func validate(headers: [String: String]) -> Bool {
        guard let providedSecret = headers[headerName.lowercased()] else {
            logger.warning("Missing auth header: \(headerName)")
            return false
        }
        
        let isValid = constantTimeCompare(providedSecret, secret)
        
        if !isValid {
            logger.warning("Invalid auth token")
        }
        
        return isValid
    }
    
    /// Constant-time string comparison to prevent timing attacks
    private func constantTimeCompare(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count else { return false }
        
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        
        var result = 0
        for i in 0..<aBytes.count {
            result |= Int(aBytes[i]) ^ Int(bBytes[i])
        }
        
        return result == 0
    }
}

/// HTTP response builder
public struct HTTPResponse {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data?
    
    public init(statusCode: Int, headers: [String: String] = [:], body: Data? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
    
    public static func ok(json: Encodable) -> HTTPResponse {
        return jsonResponse(statusCode: 200, data: json)
    }
    
    public static func created(json: Encodable) -> HTTPResponse {
        return jsonResponse(statusCode: 201, data: json)
    }
    
    public static func accepted() -> HTTPResponse {
        return HTTPResponse(statusCode: 202, headers: [:], body: nil)
    }
    
    public static func noContent() -> HTTPResponse {
        return HTTPResponse(statusCode: 204, headers: [:], body: nil)
    }
    
    public static func badRequest(message: String) -> HTTPResponse {
        return jsonResponse(statusCode: 400, data: ["error": message])
    }
    
    public static func unauthorized(message: String = "Unauthorized") -> HTTPResponse {
        return jsonResponse(statusCode: 401, data: ["error": message])
    }
    
    public static func notFound(message: String = "Not Found") -> HTTPResponse {
        return jsonResponse(statusCode: 404, data: ["error": message])
    }
    
    public static func internalError(message: String) -> HTTPResponse {
        return jsonResponse(statusCode: 500, data: ["error": message])
    }
    
    public static func text(_ text: String, statusCode: Int = 200) -> HTTPResponse {
        let data = text.data(using: .utf8)
        return HTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: data
        )
    }
    
    private static func jsonResponse(statusCode: Int, data: Encodable) -> HTTPResponse {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(data)
            
            return HTTPResponse(
                statusCode: statusCode,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: jsonData
            )
        } catch {
            let fallback = "{\"error\": \"Failed to encode response\"}".data(using: .utf8)
            return HTTPResponse(
                statusCode: 500,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: fallback
            )
        }
    }
}

/// HTTP request representation
public struct HTTPRequest {
    public let method: String
    public let path: String
    public let queryParameters: [String: String]
    public let headers: [String: String]
    public let body: Data?
    
    public init(method: String, path: String, queryParameters: [String: String] = [:], headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.queryParameters = queryParameters
        self.headers = headers
        self.body = body
    }
    
    public func decodeJSON<T: Decodable>(_ type: T.Type) throws -> T {
        guard let body = body else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Request body is empty")
            )
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: body)
    }
}

/// URL utilities
public struct URLUtils {
    public static func parseQueryString(_ query: String) -> [String: String] {
        var parameters: [String: String] = [:]
        
        let pairs = query.components(separatedBy: "&")
        for pair in pairs {
            let components = pair.components(separatedBy: "=")
            if components.count == 2 {
                let key = components[0].removingPercentEncoding ?? components[0]
                let value = components[1].removingPercentEncoding ?? components[1]
                parameters[key] = value
            }
        }
        
        return parameters
    }
    
    public static func pathComponents(_ path: String) -> [String] {
        return path.split(separator: "/").map(String.init)
    }
}
