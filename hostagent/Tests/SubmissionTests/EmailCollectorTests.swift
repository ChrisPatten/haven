import XCTest
@testable import HostAgentEmail
import Email
import HavenCore
import CryptoKit

final class EmailCollectorTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.reset()
    }
    
    func testBuildDocumentPayloadIncludesIntentPeopleAndRedaction() async throws {
        let collector = EmailCollector(
            gatewayConfig: makeGatewayConfig(),
            authToken: "secret"
        )
        
        var email = makeEmailMessage()
        email.bodyPlainText = "Hi alice@example.com, please confirm payment of $42. Call 555-123-4567."
        let intent = IntentClassification(
            primaryIntent: .receipt,
            confidence: 0.92,
            secondaryIntents: [.actionRequired],
            extractedEntities: ["amount": "42", "currency": "USD"]
        )
        
        let payload = try await collector.buildDocumentPayload(
            email: email,
            intent: intent,
            relevance: 0.87
        )
        
        XCTAssertEqual(payload.sourceType, "email_local")
        XCTAssertEqual(payload.sourceId, "email:message-123")
        XCTAssertEqual(payload.title, "Receipt for your order")
        XCTAssertEqual(payload.metadata.messageId, "message-123")
        XCTAssertEqual(payload.metadata.attachmentCount, 1)
        XCTAssertEqual(payload.metadata.intent?.primaryIntent, "receipt")
        XCTAssertEqual(payload.relevanceScore, 0.87)
        XCTAssertEqual(payload.intent?.primaryIntent, "receipt")
        XCTAssertEqual(payload.people.count, 2)
        XCTAssertEqual(payload.people.first?.identifier, "billing@example.com")
        XCTAssertEqual(payload.people.first?.role, "sender")
        XCTAssertFalse(payload.content.data.contains("alice@example.com"))
        XCTAssertFalse(payload.content.data.contains("555-123-4567"))
        
        let normalized = email.bodyPlainText?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expectedHash = sha256Hex(normalized)
        XCTAssertEqual(payload.metadata.contentHash, expectedHash)
        XCTAssertNotNil(payload.thread)
        XCTAssertEqual(payload.thread?.participants.count, 2)
    }
    
    func testSubmitEmailDocumentSendsIdempotencyKeyAndPayload() async throws {
        let session = makeMockSession()
        let collector = EmailCollector(
            gatewayConfig: makeGatewayConfig(),
            authToken: "secret",
            session: session
        )
        
        let email = makeEmailMessage()
        let payload = try await collector.buildDocumentPayload(email: email)
        
        var callCount = 0
        MockURLProtocol.requestHandler = { request in
            callCount += 1
            XCTAssertEqual(request.url?.path, "/v1/ingest")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            
            let expectedIdempotency = EmailCollector.makeDocumentIdempotencyKey(
                sourceType: payload.sourceType,
                sourceId: payload.sourceId,
                textHash: payload.metadata.contentHash
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), expectedIdempotency)
            
            guard let body = self.bodyData(from: request) else {
                XCTFail("Missing request body")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data())
            }
            let object = try JSONSerialization.jsonObject(with: body, options: [])
            guard
                let json = object as? [String: Any],
                let sourceId = json["source_id"] as? String,
                let metadata = json["metadata"] as? [String: Any],
                let messageId = metadata["message_id"] as? String
            else {
                XCTFail("Failed to inspect request body")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data())
            }
            XCTAssertEqual(sourceId, payload.sourceId)
            XCTAssertEqual(messageId, payload.metadata.messageId)
            
            let responseBody = """
            {
                "submission_id": "sub-1",
                "doc_id": "doc-1",
                "external_id": "\(payload.sourceId)",
                "status": "embedding_pending",
                "thread_id": null,
                "file_ids": [],
                "duplicate": false,
                "total_chunks": 3
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 202,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseBody)
        }
        
        let response = try await collector.submitEmailDocument(payload)
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(response.submissionId, "sub-1")
        XCTAssertEqual(response.docId, "doc-1")
        XCTAssertEqual(response.externalId, payload.sourceId)
    }
    
    func testSubmitEmailAttachmentRetriesOn429AndIncludesMetadata() async throws {
        let session = makeMockSession()
        let collector = EmailCollector(
            gatewayConfig: makeGatewayConfig(),
            authToken: "secret",
            session: session
        )
        
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("sample.txt")
        try "Attachment contents".data(using: .utf8)?.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        
        var email = makeEmailMessage()
        email.attachments = [
            EmailAttachment(filename: "sample.txt", mimeType: "text/plain", contentId: "cid-1", size: 18, partIndex: 0)
        ]
        let payload = try await collector.buildDocumentPayload(email: email)
        
        var callCount = 0
        MockURLProtocol.requestHandler = { request in
            callCount += 1
            XCTAssertEqual(request.url?.path, "/v1/ingest/file")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") ?? false)
            
            guard let bodyData = self.bodyData(from: request),
                  let bodyString = String(data: bodyData, encoding: .utf8) else {
                XCTFail("Missing body data")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data())
            }
            XCTAssertTrue(bodyString.contains("\"source\":\"email_local\""))
            XCTAssertTrue(bodyString.contains("\"content_id\":\"cid-1\""))
            
            if callCount == 1 {
                let retryResponse = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "1"]
                )!
                return (retryResponse, Data("retry".utf8))
            }
            
            let responseBody = """
            {
                "submission_id": "sub-file-1",
                "doc_id": "doc-1",
                "external_id": "\(payload.sourceId)",
                "status": "ready",
                "thread_id": null,
                "file_ids": ["file-1"],
                "duplicate": false,
                "total_chunks": 0,
                "file_sha256": "abc123",
                "object_key": "obj-1",
                "extraction_status": "ready"
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 202,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseBody)
        }
        
        let attachment = email.attachments[0]
        let enrichment = EmailAttachmentEnrichment(ocrText: "Receipt", entities: ["amount": ["42.00"]], caption: "Receipt image")
        let response = try await collector.submitEmailAttachment(
            fileURL: fileURL,
            attachment: attachment,
            messageId: payload.metadata.messageId,
            intent: nil,
            relevance: 0.9,
            enrichment: enrichment
        )
        
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(response.submissionId, "sub-file-1")
        XCTAssertEqual(response.fileSha256, "abc123")
    }
    
    // MARK: - Helpers
    
    private func makeGatewayConfig() -> GatewayConfig {
        GatewayConfig(
            baseUrl: "http://gateway.test",
            ingestPath: "/v1/ingest",
            ingestFilePath: "/v1/ingest/file",
            timeout: 5
        )
    }
    
    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    
    private func makeEmailMessage() -> EmailMessage {
        EmailMessage(
            messageId: "message-123",
            subject: "Receipt for your order",
            from: ["Billing <billing@example.com>"],
            to: ["alice@example.com"],
            date: Date(timeIntervalSince1970: 1_720_000_000),
            inReplyTo: "parent-456",
            references: ["parent-456", "root-001"],
            listUnsubscribe: "<mailto:unsubscribe@example.com>",
            bodyPlainText: "Hello world",
            attachments: [
                EmailAttachment(filename: "invoice.pdf", mimeType: "application/pdf", contentId: "cid-123", size: 2048, partIndex: 0)
            ],
            headers: [
                "Message-ID": "<message-123>",
                "In-Reply-To": "<parent-456>"
            ]
        )
    }
    
    private func sha256Hex(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func bodyData(from request: URLRequest) -> Data? {
        if let data = request.httpBody {
            return data
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var buffer = Data()
        let chunkSize = 1024
        var temp = [UInt8](repeating: 0, count: chunkSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&temp, maxLength: chunkSize)
            if read <= 0 {
                break
            }
            buffer.append(temp, count: read)
        }
        return buffer
    }
}

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            fatalError("Handler not set")
        }
        
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    override func stopLoading() {}
    
    static func reset() {
        requestHandler = nil
    }
}
