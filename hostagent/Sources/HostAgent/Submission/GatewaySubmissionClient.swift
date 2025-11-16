import Foundation
import HavenCore

struct GatewayBatchSubmissionResult: @unchecked Sendable {
    let statusCode: Int
    let submission: GatewaySubmissionResponse?
    let errorCode: String?
    let errorMessage: String?
    let retryable: Bool

    init(
        statusCode: Int,
        submission: GatewaySubmissionResponse? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        retryable: Bool = false
    ) {
        self.statusCode = statusCode
        self.submission = submission
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.retryable = retryable
    }
}

public actor GatewaySubmissionClient {
    private let config: GatewayConfig
    private let authToken: String
    private let session: URLSession
    private let timeout: TimeInterval
    private let logger = HavenLogger(category: "gateway-submission")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    
    public init(config: GatewayConfig, authToken: String, session: URLSession? = nil) {
        self.config = config
        self.authToken = authToken
        self.timeout = TimeInterval(config.timeoutMs) / 1000.0
        if let providedSession = session {
            self.session = providedSession
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = TimeInterval(config.timeoutMs) / 1000.0
            configuration.timeoutIntervalForResource = TimeInterval(config.timeoutMs) / 1000.0
            self.session = URLSession(configuration: configuration)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }
    
    func submitDocument(payload: EmailDocumentPayload, idempotencyKey: String) async throws -> GatewaySubmissionResponse {
        let urlString = config.baseUrl + config.ingestPath
        guard let url = URL(string: urlString) else {
            throw EmailCollectorError.gatewayInvalidResponse
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try encoder.encode(payload)
        
        let data = try await performRequest(request: request)
        return try decode(GatewaySubmissionResponse.self, from: data)
    }

    func submitDocumentsBatch(payloads: [EmailDocumentPayload]) async throws -> [GatewayBatchSubmissionResult]? {
        guard !payloads.isEmpty else { return [] }

        let requestPayload = BatchSubmitRequest(documents: payloads)
        let requestData = try encoder.encode(requestPayload)
        let candidatePaths = batchEndpointCandidates(for: config.ingestPath)

        for path in candidatePaths {
            // Build URL using URLComponents to avoid unwanted percent-encoding of path
            guard let baseURL = URL(string: config.baseUrl) else {
                logger.error("Invalid gateway base url", metadata: ["base_url": config.baseUrl])
                continue
            }

            guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
                logger.error("Failed to create URLComponents for gateway base url", metadata: ["base_url": config.baseUrl])
                continue
            }

            // Preserve existing base path and append candidate path. Set percentEncodedPath
            // directly so characters like ':' are not further escaped.
            let basePath = comps.percentEncodedPath
            let trimmedBasePath = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
            let newPercentEncodedPath = trimmedBasePath + path
            comps.percentEncodedPath = newPercentEncodedPath

            guard let url = comps.url else {
                logger.error("Failed to compose gateway batch URL", metadata: ["base_url": config.baseUrl, "path": path])
                continue
            }
            let urlString = url.absoluteString
            logger.debug("Gateway batch URL", metadata: ["url": urlString])

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = requestData

            do {
                let data = try await performRequest(request: request)
                let response = try decoder.decode(BatchSubmitResponse.self, from: data)
                return mapBatchResponse(response: response, total: payloads.count)
            } catch let error as EmailCollectorError {
                switch error {
                case .gatewayHTTPError(let statusCode, _ ) where statusCode == 404 || statusCode == 405:
                    logger.info("Gateway batch endpoint unavailable", metadata: [
                        "url": urlString,
                        "status": "\(statusCode)"
                    ])
                    continue
                default:
                    logger.error("Gateway batch ingest failed", metadata: [
                        "url": urlString,
                        "error": error.localizedDescription
                    ])
                    continue
                }
            } catch {
                logger.error("Gateway batch ingest unexpected error", metadata: [
                    "url": urlString,
                    "error": error.localizedDescription
                ])
                continue
            }
        }

        return nil
    }
    
    func submitAttachment(
        fileURL: URL,
        data: Data,
        metadata: EmailAttachmentMeta,
        idempotencyKey: String,
        mimeType: String
    ) async throws -> GatewayFileSubmissionResponse {
        return try await submitFile(
            fileURL: fileURL,
            data: data,
            metadata: metadata,
            filename: metadata.filename ?? fileURL.lastPathComponent,
            idempotencyKey: idempotencyKey,
            mimeType: mimeType
        )
    }
    
    public func submitFile<M: Encodable>(
        fileURL: URL,
        data: Data,
        metadata: M,
        filename: String,
        idempotencyKey: String,
        mimeType: String
    ) async throws -> GatewayFileSubmissionResponse {
        let urlString = config.baseUrl + config.ingestFilePath
        guard let url = URL(string: urlString) else {
            throw EmailCollectorError.gatewayInvalidResponse
        }
        
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        let metaData = try encoder.encode(metadata)
        
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"meta\"\r\n")
        body.append("Content-Type: application/json\r\n\r\n")
        if let metaString = String(data: metaData, encoding: .utf8) {
            body.append(metaString)
        }
        body.append("\r\n")
        
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"upload\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = body
        
        let responseData = try await performRequest(request: request)
        return try decode(GatewayFileSubmissionResponse.self, from: responseData)
    }
    
    private func batchEndpointCandidates(for basePath: String) -> [String] {
        // Only use the colon version: /v1/ingest:batch
        let colonPath = basePath.hasSuffix(":batch") ? basePath : basePath + ":batch"
        return [colonPath]
    }

    private func mapBatchResponse(response: BatchSubmitResponse, total: Int) -> [GatewayBatchSubmissionResult] {
        var mapped = Array(
            repeating: GatewayBatchSubmissionResult(
                statusCode: 0,
                submission: nil,
                errorCode: nil,
                errorMessage: nil,
                retryable: false
            ),
            count: total
        )

        for result in response.results {
            guard result.index >= 0 && result.index < total else { continue }
            let errorInfo = result.error
            mapped[result.index] = GatewayBatchSubmissionResult(
                statusCode: result.statusCode,
                submission: result.submission,
                errorCode: errorInfo?.errorCode,
                errorMessage: errorInfo?.message,
                retryable: errorInfo?.retryable ?? false
            )
        }

        for index in 0..<total where mapped[index].statusCode == 0 && mapped[index].submission == nil {
            mapped[index] = GatewayBatchSubmissionResult(
                statusCode: 502,
                submission: nil,
                errorCode: "INGEST.BATCH_MISSING_RESULT",
                errorMessage: "Batch response missing entry for index \(index)",
                retryable: true
            )
        }

        return mapped
    }

    private struct BatchSubmitRequest: Encodable {
        let documents: [EmailDocumentPayload]
    }

    private struct BatchSubmitResponse: Decodable {
        let successCount: Int?
        let failureCount: Int?
        let results: [BatchSubmitResult]

        private enum CodingKeys: String, CodingKey {
            case successCount = "success_count"
            case failureCount = "failure_count"
            case results
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            successCount = try container.decodeIfPresent(Int.self, forKey: .successCount)
            failureCount = try container.decodeIfPresent(Int.self, forKey: .failureCount)
            results = try container.decodeIfPresent([BatchSubmitResult].self, forKey: .results) ?? []
        }
    }

    private struct BatchSubmitResult: Decodable {
        let index: Int
        let statusCode: Int
        let submission: GatewaySubmissionResponse?
        let error: BatchSubmitError?

        private enum CodingKeys: String, CodingKey {
            case index
            case statusCode = "status_code"
            case submission
            case error
        }
    }

    private struct BatchSubmitError: Decodable {
        let errorCode: String
        let message: String
        let retryable: Bool

        private enum CodingKeys: String, CodingKey {
            case errorCode = "error_code"
            case message
            case retryable
        }
    }

// MARK: - Internal helpers
    
    private func performRequest(request: URLRequest) async throws -> Data {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw EmailCollectorError.gatewayInvalidResponse
                }
                
                if (200...299).contains(httpResponse.statusCode) {
                    return data
                }
                
                let body = String(data: data, encoding: .utf8) ?? ""
                logger.warning("Gateway returned non-success status", metadata: [
                    "status": "\(httpResponse.statusCode)",
                    "body": body,
                    "attempt": "\(attempt)"
                ])
                
                if shouldRetry(statusCode: httpResponse.statusCode), attempt < maxAttempts {
                    let delay = UInt64(Double(attempt) * 0.5 * 1_000_000_000)
                    try await Task.sleep(nanoseconds: delay)
                    continue
                } else {
                    throw EmailCollectorError.gatewayHTTPError(httpResponse.statusCode, body)
                }
            } catch let error as EmailCollectorError {
                throw error
            } catch {
                logger.error("Gateway request failed", metadata: [
                    "error": error.localizedDescription,
                    "attempt": "\(attempt)"
                ])
                if attempt < maxAttempts {
                    let delay = UInt64(Double(attempt) * 0.5 * 1_000_000_000)
                    try await Task.sleep(nanoseconds: delay)
                    continue
                }
                throw EmailCollectorError.gatewayHTTPError(-1, error.localizedDescription)
            }
        }
        throw EmailCollectorError.gatewayHTTPError(-1, "Exceeded retry attempts")
    }
    
    private func shouldRetry(statusCode: Int) -> Bool {
        return statusCode == 429 || statusCode == 503
    }
    
    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            logger.error("Failed to decode gateway response", metadata: ["error": error.localizedDescription, "body": body])
            throw error
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
