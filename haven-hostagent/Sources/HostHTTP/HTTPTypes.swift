import Foundation
import NIOHTTP1

public struct HostHTTPRequest: Sendable {
    public let method: HTTPMethod
    public let uri: String
    public let path: String
    public let query: [String: String]
    public let headers: HTTPHeaders
    public let body: Data
    public let remoteAddress: String?

    public func header(_ name: String) -> String? {
        headers.first(name: name)
    }
}

public struct HostHTTPResponse: Sendable {
    public let status: HTTPResponseStatus
    public let headers: HTTPHeaders
    public let body: Data

    public static func json<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) -> HostHTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data()
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(data.count)")
        return HostHTTPResponse(status: status, headers: headers, body: data)
    }

    public static func text(_ value: String, status: HTTPResponseStatus = .ok, contentType: String = "text/plain; charset=utf-8") -> HostHTTPResponse {
        let data = Data(value.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(data.count)")
        return HostHTTPResponse(status: status, headers: headers, body: data)
    }

    public static func noContent() -> HostHTTPResponse {
        HostHTTPResponse(status: .noContent, headers: HTTPHeaders(), body: Data())
    }
}
