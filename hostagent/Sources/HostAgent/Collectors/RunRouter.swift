import Foundation
import HavenCore

public struct RunResponse: Encodable {
    public var status: String
    public var collector: String
    public var run_id: String?
    public var started_at: String
    public var finished_at: String?
    public var stats: [String: Int]?
    public var warnings: [String]?
    public var errors: [String]?
    public var inner_status_code: Int?
    public var inner_body: String?

    public init(status: String, collector: String, runId: String? = nil, startedAt: Date = Date(), finishedAt: Date? = nil, stats: [String: Int]? = nil, warnings: [String]? = nil, errors: [String]? = nil, innerStatus: Int? = nil, innerBody: String? = nil) {
        self.status = status
        self.collector = collector
        self.run_id = runId
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.started_at = fmt.string(from: startedAt)
        if let finishedAt = finishedAt {
            self.finished_at = fmt.string(from: finishedAt)
        } else {
            self.finished_at = nil
        }
        self.stats = stats
        self.warnings = warnings
        self.errors = errors
        self.inner_status_code = innerStatus
        self.inner_body = innerBody
    }
}

public enum RunRouterError: Error {
    case invalidJSON(String)
}

public struct RunRouter {
    /// Dispatch map maps collector name -> handler closure
    public static func handle(request: HTTPRequest, context: RequestContext, dispatchMap: [String: (HTTPRequest, RequestContext) async -> HTTPResponse]) async -> HTTPResponse {
        let prefix = "/v1/collectors/"
        let suffix = ":run"
        guard request.path.hasPrefix(prefix) && request.path.hasSuffix(suffix) else {
            return HTTPResponse.notFound()
        }

        let startIndex = request.path.index(request.path.startIndex, offsetBy: prefix.count)
        let endIndex = request.path.index(request.path.endIndex, offsetBy: -suffix.count)
        let collectorName = String(request.path[startIndex..<endIndex])

        // Strict decode into CollectorRunRequest to reject unknown fields.
        do {
            _ = try request.decodeJSON(CollectorRunRequest.self)
        } catch let decodingErr as DecodingError {
            return HTTPResponse.badRequest(message: "Invalid request JSON: \(decodingErr.localizedDescription)")
        } catch {
            return HTTPResponse.badRequest(message: "Invalid request JSON: \(error.localizedDescription)")
        }

        guard let handler = dispatchMap[collectorName] else {
            return HTTPResponse.notFound(message: "Unknown collector '\(collectorName)'")
        }

        // Call underlying handler and capture response
        let inner = await handler(request, context)

        // Build RunResponse envelope
        var innerBodyString: String? = nil
        if let body = inner.body, let s = String(data: body, encoding: .utf8) {
            innerBodyString = s
        }

        let status: String = (200...299).contains(inner.statusCode) ? "ok" : "error"
        let runResp = RunResponse(status: status, collector: collectorName, runId: nil, startedAt: Date(), finishedAt: Date(), stats: nil, warnings: nil, errors: nil, innerStatus: inner.statusCode, innerBody: innerBodyString)

        return HTTPResponse.ok(json: runResp)
    }
}
