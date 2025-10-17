import Foundation
import Logging

public struct GatewayResponseError: Error, Sendable {
    public let statusCode: Int
    public let body: String
}

public protocol GatewayTransport: Sendable {
    func ingest<Event: Encodable>(events: [Event]) async throws
    func requestPresignedPut(path: String, sha256: String, size: Int64) async throws -> URL
    func notifyFileIngested(_ event: FileIngestEvent) async throws
    func upload(fileData: Data, to url: URL) async throws
}

public final class GatewayClient: GatewayTransport, @unchecked Sendable {
    private let logger = Logger(label: "HostAgent.GatewayClient")
    private let session: URLSession
    private let baseURL: URL
    private let ingestPath: String
    private let authHeader: String
    private let authSecret: String

    public init(configuration: HostAgentConfiguration) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)
        baseURL = configuration.gateway.baseURL
        ingestPath = configuration.gateway.ingestPath
        authHeader = configuration.auth.header
        authSecret = configuration.auth.secret
    }

    public func ingest<Event: Encodable>(events: [Event]) async throws {
        let url = baseURL.appendingPathComponent(ingestPath)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(authSecret, forHTTPHeaderField: authHeader)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(events)
        request.httpBody = payload

        logger.debug("Sending ingest batch", metadata: ["count": "\(events.count)"])
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GatewayResponseError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    public func requestPresignedPut(path: String, sha256: String, size: Int64) async throws -> URL {
        let url = baseURL.appendingPathComponent("/v1/storage/presign")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(authSecret, forHTTPHeaderField: authHeader)

        struct Payload: Encodable { let path: String; let sha256: String; let size: Int64 }

        request.httpBody = try JSONEncoder().encode(Payload(path: path, sha256: sha256, size: size))
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GatewayResponseError(statusCode: -1, body: "non-http response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GatewayResponseError(statusCode: httpResponse.statusCode, body: body)
        }
        let decoded = try JSONDecoder().decode(PresignResponse.self, from: data)
        guard let url = URL(string: decoded.url) else {
            throw GatewayResponseError(statusCode: httpResponse.statusCode, body: "invalid url")
        }
        return url
    }

    public func notifyFileIngested(_ event: FileIngestEvent) async throws {
        let url = baseURL.appendingPathComponent("/v1/localfs/events")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(authSecret, forHTTPHeaderField: authHeader)
        request.httpBody = try JSONEncoder().encode(event)
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw GatewayResponseError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: "failed to notify gateway")
        }
    }

    public func upload(fileData: Data, to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.addValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, from: fileData)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw GatewayResponseError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: "failed to upload file")
        }
    }
}

private struct PresignResponse: Decodable {
    let url: String
}

public struct FileIngestEvent: Codable, Sendable {
    public let id: String
    public let path: String
    public let sha256: String
    public let size: Int64
    public let modifiedAt: Date

    public init(id: String, path: String, sha256: String, size: Int64, modifiedAt: Date) {
        self.id = id
        self.path = path
        self.sha256 = sha256
        self.size = size
        self.modifiedAt = modifiedAt
    }
}
