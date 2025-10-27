import Foundation
@_spi(Generated) import OpenAPIRuntime
@preconcurrency import HavenCore

/// Implementation of the OpenAPI-generated APIProtocol.
/// Delegates to existing handler implementations while using generated types.
public final class APIHandler: APIProtocol {
    private let config: HavenConfig
    private let iMessageHandler: IMessageHandler
    private let emailImapHandler: EmailImapHandler

    public init(config: HavenConfig) {
        self.config = config

        // Initialize gateway client for handlers
        let gatewayClient = GatewayClient(config: config.gateway, authToken: config.auth.secret)

        self.iMessageHandler = IMessageHandler(config: config, gatewayClient: gatewayClient)
        self.emailImapHandler = EmailImapHandler(config: config)
    }

    /// Execute a collector run
    ///
    /// Runs a collection pass with deterministic ordering and state/coverage handling.
    /// If both date_range and time_window are omitted, the server may use a default lookback window.
    internal func postV1CollectorsCollector_colon_run(
        _ input: Operations.PostV1CollectorsCollector_colon_run.Input
    ) async throws -> Operations.PostV1CollectorsCollector_colon_run.Output {
        // Extract the collector type from the path
        let collector = input.path.collector

        // Create a mock HTTPRequest and RequestContext for the existing handlers
        // The existing handlers expect HTTPRequest/HTTPResponse, so we need to bridge
        let mockRequest = createMockHTTPRequest(from: input)
        let mockContext = RequestContext()

        // Delegate to the appropriate handler
        let response: HTTPResponse
        switch collector {
        case .imessage:
            response = await iMessageHandler.handleRun(request: mockRequest, context: mockContext)
        case .emailImap:
            response = await emailImapHandler.handleRun(request: mockRequest, context: mockContext)
        }

        // Convert the HTTPResponse back to the generated Output type
        return try convertToOutput(response)
    }

    private func createMockHTTPRequest(from input: Operations.PostV1CollectorsCollector_colon_run.Input) -> HTTPRequest {
        // Convert the generated input types back to HTTPRequest for compatibility
        let path = "/v1/collectors/\(input.path.collector.rawValue):run"

        // Serialize the body back to JSON
        let bodyData: Data
        switch input.body {
        case .json(let runRequest):
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            bodyData = try! encoder.encode(runRequest)
        }

        return HTTPRequest(
            method: "POST",
            path: path,
            queryParameters: [:],
            headers: [:], // Headers are handled by OpenAPI runtime
            body: bodyData
        )
    }

    private func convertToOutput(_ response: HTTPResponse) throws -> Operations.PostV1CollectorsCollector_colon_run.Output {
        switch response.statusCode {
        case 200:
            // Parse the response body as RunResponse
            guard let bodyData = response.body else {
                throw APIError.invalidResponse("Missing response body")
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let runResponse = try decoder.decode(Components.Schemas.RunResponse.self, from: bodyData)

            return .ok(.init(body: .json(runResponse)))

        case 400:
            // Parse error response
            let errorBody: Components.Schemas._Error
            if let bodyData = response.body {
                let decoder = JSONDecoder()
                errorBody = try decoder.decode(Components.Schemas._Error.self, from: bodyData)
            } else {
                errorBody = .init(error: "bad_request", message: "Bad Request")
            }
            return .badRequest(.init(body: .json(errorBody)))

        case 500:
            // Parse error response
            let errorBody: Components.Schemas._Error
            if let bodyData = response.body {
                let decoder = JSONDecoder()
                errorBody = try decoder.decode(Components.Schemas._Error.self, from: bodyData)
            } else {
                errorBody = .init(error: "internal_server_error", message: "Internal Server Error")
            }
            return .internalServerError(.init(body: .json(errorBody)))

        default:
            // For any other status code, treat as internal server error
            let errorBody = Components.Schemas._Error(error: "unexpected_status", message: "Unexpected status code: \(response.statusCode)")
            return .internalServerError(.init(body: .json(errorBody)))
        }
    }
}

enum APIError: Error {
    case invalidResponse(String)
}