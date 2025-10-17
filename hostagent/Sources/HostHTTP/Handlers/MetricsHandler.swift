import Foundation
import HavenCore

/// Handler for GET /v1/metrics
public struct MetricsHandler {
    private let logger = HavenLogger(category: "metrics")
    
    public init() {}
    
    public func handle(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        let metricsText = await MetricsCollector.shared.prometheusFormat()
        
        logger.debug("Metrics exported", metadata: [
            "request_id": context.requestId
        ])
        
        return HTTPResponse.text(metricsText)
    }
}
