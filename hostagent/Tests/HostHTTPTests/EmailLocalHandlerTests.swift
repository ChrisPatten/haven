import XCTest
@testable import HostHTTP
import HavenCore
import Email
@testable import HostAgentEmail
import CryptoKit

final class EmailLocalHandlerTests: XCTestCase {
    func testSimulateRunProcessesFixtureAndUpdatesState() async throws {
        let mockCollector = MockEmailCollector()
        let (config, _) = makeConfig(mailEnabled: true)
        let handler = EmailLocalHandler(
            config: config,
            emailCollector: mockCollector
        )
        let fixturePath = try XCTUnwrap(Bundle.module.url(
            forResource: "simulated-email",
            withExtension: "emlx",
            subdirectory: "Fixtures"
        )?.path)
        
        let requestBody: [String: Any] = [
            "mode": "simulate",
            "simulate_path": fixturePath,
            "limit": 5
        ]
        let requestData = try JSONSerialization.data(withJSONObject: requestBody)
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/collectors/email_local:run",
            headers: ["Content-Type": "application/json"],
            body: requestData
        )
        
        let response = await handler.handleRun(request: request, context: RequestContext())
        XCTAssertEqual(response.statusCode, 200)
        
        let payload = try decodeJSONDictionary(from: response.body)
        XCTAssertEqual(payload["status"] as? String, "completed")
        let stats = payload["stats"] as? [String: Any]
        XCTAssertEqual(stats?["messages_processed"] as? Int, 1)
        XCTAssertEqual(stats?["documents_created"] as? Int, 1)
        XCTAssertEqual(stats?["attachments_processed"] as? Int, 0)
        XCTAssertEqual(stats?["errors_encountered"] as? Int, 0)
        XCTAssertNotNil(stats?["start_time"] as? String)
        XCTAssertNotNil(stats?["end_time"] as? String)
        
        let stateResponse = await handler.handleState(
            request: HTTPRequest(method: "GET", path: "/v1/collectors/email_local/state"),
            context: RequestContext()
        )
        XCTAssertEqual(stateResponse.statusCode, 200)
        let state = try decodeJSONDictionary(from: stateResponse.body)
        XCTAssertEqual(state["status"] as? String, "completed")
        XCTAssertEqual(state["is_running"] as? Bool, false)
        XCTAssertNil(state["last_run_error"])
        XCTAssertNotNil(state["last_run_stats"] as? [String: Any])
        
        let builtCount = await mockCollector.builtPayloadCount()
        let submittedDocs = await mockCollector.submittedDocumentCount()
        let submittedAttachments = await mockCollector.submittedAttachmentCount()
        XCTAssertEqual(builtCount, 1)
        XCTAssertEqual(submittedDocs, 0)
        XCTAssertEqual(submittedAttachments, 0)
    }
    
    func testRunRejectedWhenModuleDisabled() async throws {
        let (config, _) = makeConfig(mailEnabled: false)
        let handler = EmailLocalHandler(
            config: config,
            emailCollector: MockEmailCollector()
        )
        let request = HTTPRequest(method: "POST", path: "/v1/collectors/email_local:run")
        
        let response = await handler.handleRun(request: request, context: RequestContext())
        XCTAssertEqual(response.statusCode, 503)
        
        let payload = try decodeJSONDictionary(from: response.body)
        XCTAssertEqual(payload["error"] as? String, "Email collector module is disabled")
    }
    
    func testConcurrentRunReturnsConflict() async throws {
        let (config, _) = makeConfig(mailEnabled: true)
        let handler = EmailLocalHandler(
            config: config,
            emailCollector: MockEmailCollector()
        )
        let fixturePath = try XCTUnwrap(Bundle.module.url(
            forResource: "simulated-email",
            withExtension: "emlx",
            subdirectory: "Fixtures"
        )?.path)
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        
        for index in 0..<200 {
            let destination = tempDirectory.appendingPathComponent("email-\(index).emlx")
            try FileManager.default.copyItem(atPath: fixturePath, toPath: destination.path)
        }
        
        let requestBody: [String: Any] = [
            "mode": "simulate",
            "simulate_path": tempDirectory.path,
            "limit": 200
        ]
        let requestData = try JSONSerialization.data(withJSONObject: requestBody)
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/collectors/email_local:run",
            headers: ["Content-Type": "application/json"],
            body: requestData
        )
        
        async let firstResponse = handler.handleRun(request: request, context: RequestContext())
        try await Task.sleep(nanoseconds: 20_000_000) // 20ms to ensure first run enters processing
        let conflictResponse = await handler.handleRun(request: request, context: RequestContext())
        XCTAssertEqual(conflictResponse.statusCode, 409)
        
        let payload = try decodeJSONDictionary(from: conflictResponse.body)
        XCTAssertEqual(payload["error"] as? String, "Collector is already running")
        
        _ = await firstResponse
    }
    
    func testMissingPathProducesFailureState() async throws {
        let (config, _) = makeConfig(mailEnabled: true)
        let handler = EmailLocalHandler(
            config: config,
            emailCollector: MockEmailCollector()
        )
        let requestBody: [String: Any] = [
            "mode": "simulate",
            "simulate_path": "/nonexistent/path"
        ]
        let requestData = try JSONSerialization.data(withJSONObject: requestBody)
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/collectors/email_local:run",
            headers: ["Content-Type": "application/json"],
            body: requestData
        )
        
        let response = await handler.handleRun(request: request, context: RequestContext())
        XCTAssertEqual(response.statusCode, 404)
        
        let stateResponse = await handler.handleState(
            request: HTTPRequest(method: "GET", path: "/v1/collectors/email_local/state"),
            context: RequestContext()
        )
        let state = try decodeJSONDictionary(from: stateResponse.body)
        XCTAssertEqual(state["status"] as? String, "failed")
        XCTAssertNotNil(state["last_run_error"] as? String)
    }
    
    func testRealRunProcessesEnvelopeIndex() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        let stateURL = tempRoot.appendingPathComponent("state.json")
        let builder = try MailFixtureBuilder(root: tempRoot)
        let mailbox = try builder.createMailbox(name: "INBOX", displayName: "Inbox")
        try builder.addMessage(mailbox: mailbox, subject: "Indexed", remoteID: "999", flags: 0)
        let collector = EmailIndexedCollector(mailRoot: builder.mailRoot, stateFileURL: stateURL)
        let mockCollector = MockEmailCollector()
        let (config, _) = makeConfig(mailEnabled: true)
        let handler = EmailLocalHandler(
            config: config,
            indexedCollector: collector,
            emailCollector: mockCollector
        )
        let requestBody: [String: Any] = ["mode": "real", "limit": 10]
        let requestData = try JSONSerialization.data(withJSONObject: requestBody)
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/collectors/email_local:run",
            headers: ["Content-Type": "application/json"],
            body: requestData
        )
        let response = await handler.handleRun(request: request, context: RequestContext())
        XCTAssertEqual(response.statusCode, 200)
        let payload = try decodeJSONDictionary(from: response.body)
        XCTAssertEqual(payload["status"] as? String, "completed")
        let stats = try XCTUnwrap(payload["stats"] as? [String: Any])
        XCTAssertEqual(stats["messages_processed"] as? Int, 1)
        XCTAssertEqual(stats["documents_created"] as? Int, 1)
        XCTAssertNil(payload["warnings"])
        let stateData = try Data(contentsOf: stateURL)
        let stateJSON = try JSONSerialization.jsonObject(with: stateData) as? [String: Any]
        XCTAssertEqual(stateJSON?["lastRowID"] as? Int, 1)
        let stateResponse = await handler.handleState(
            request: HTTPRequest(method: "GET", path: "/v1/collectors/email_local/state"),
            context: RequestContext()
        )
        let statePayload = try decodeJSONDictionary(from: stateResponse.body)
        let runState = try XCTUnwrap(statePayload["run_state"] as? [String: Any])
        XCTAssertEqual(runState["last_accepted_rowid"] as? Int, 1)
        let runEntries = try XCTUnwrap(runState["entries"] as? [[String: Any]])
        XCTAssertEqual(runEntries.count, 1)
        XCTAssertEqual(runEntries.first?["status"] as? String, "accepted")
        let submittedDocuments = await mockCollector.submittedDocumentCount()
        XCTAssertEqual(submittedDocuments, 1)
    }
    
    func testRealRunSkipsDuplicateEmlxPaths() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        let stateURL = tempRoot.appendingPathComponent("state.json")
        let builder = try MailFixtureBuilder(root: tempRoot)
        let mailbox = try builder.createMailbox(name: "INBOX", displayName: "Inbox")
        try builder.addMessage(mailbox: mailbox, subject: "Original", remoteID: "dup", flags: 0)
        // Insert a second envelope record that points at the same .emlx file.
        try builder.addMessage(mailbox: mailbox, subject: "Duplicate", remoteID: "dup", flags: 0)
        let collector = EmailIndexedCollector(mailRoot: builder.mailRoot, stateFileURL: stateURL)
        let mockCollector = MockEmailCollector()
        let (config, _) = makeConfig(mailEnabled: true)
        let handler = EmailLocalHandler(
            config: config,
            indexedCollector: collector,
            emailCollector: mockCollector
        )
        let requestBody: [String: Any] = ["mode": "real", "limit": 10]
        let requestData = try JSONSerialization.data(withJSONObject: requestBody)
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/collectors/email_local:run",
            headers: ["Content-Type": "application/json"],
            body: requestData
        )

        let response = await handler.handleRun(request: request, context: RequestContext())
        XCTAssertEqual(response.statusCode, 200)
        let payload = try decodeJSONDictionary(from: response.body)
        XCTAssertEqual(payload["status"] as? String, "partial")
        let warnings = try XCTUnwrap(payload["warnings"] as? [String])
        XCTAssertTrue(warnings.contains { $0.contains("Duplicate Envelope Index entry") })
        let stats = try XCTUnwrap(payload["stats"] as? [String: Any])
        XCTAssertEqual(stats["messages_processed"] as? Int, 1)
        XCTAssertEqual(stats["documents_created"] as? Int, 1)

        let submittedDocuments = await mockCollector.submittedDocumentCount()
        XCTAssertEqual(submittedDocuments, 1)
        let builtPayloads = await mockCollector.builtPayloadCount()
        XCTAssertEqual(builtPayloads, 1)
    }
    
    func testRealRunFallsBackWhenEnvelopeMissing() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        let collector = EmailIndexedCollector(mailRoot: tempRoot, stateFileURL: tempRoot.appendingPathComponent("state.json"))
        let (config, _) = makeConfig(mailEnabled: true)
        let handler = EmailLocalHandler(
            config: config,
            indexedCollector: collector,
            emailCollector: MockEmailCollector()
        )
        let requestBody: [String: Any] = ["mode": "real", "limit": 5]
        let requestData = try JSONSerialization.data(withJSONObject: requestBody)
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/collectors/email_local:run",
            headers: ["Content-Type": "application/json"],
            body: requestData
        )
        let response = await handler.handleRun(request: request, context: RequestContext())
        XCTAssertEqual(response.statusCode, 200)
        let payload = try decodeJSONDictionary(from: response.body)
        XCTAssertEqual(payload["status"] as? String, "partial")
        let warnings = try XCTUnwrap(payload["warnings"] as? [String])
        XCTAssertFalse(warnings.isEmpty)
    }

    func testRealRunWithTransientFailurePersistsSubmissionState() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        let stateURL = tempRoot.appendingPathComponent("state.json")
        let builder = try MailFixtureBuilder(root: tempRoot)
        let mailbox = try builder.createMailbox(name: "INBOX", displayName: "Inbox")
        try builder.addMessage(mailbox: mailbox, subject: "Transient", remoteID: "t-1", flags: 0)
        let collector = EmailIndexedCollector(mailRoot: builder.mailRoot, stateFileURL: stateURL)
        let mockCollector = MockEmailCollector()
        await mockCollector.setDocumentSubmissionError(EmailCollectorError.gatewayHTTPError(503, "Service Unavailable"))
        let (config, stateRoot) = makeConfig(mailEnabled: true)
        defer { try? fm.removeItem(at: stateRoot) }
        let handler = EmailLocalHandler(
            config: config,
            indexedCollector: collector,
            emailCollector: mockCollector
        )
        let requestBody: [String: Any] = ["mode": "real", "limit": 5]
        let requestData = try JSONSerialization.data(withJSONObject: requestBody)
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/collectors/email_local:run",
            headers: ["Content-Type": "application/json"],
            body: requestData
        )
        let response = await handler.handleRun(request: request, context: RequestContext())
        XCTAssertEqual(response.statusCode, 200)
        let payload = try decodeJSONDictionary(from: response.body)
        XCTAssertEqual(payload["status"] as? String, "partial")
        let warnings = payload["warnings"] as? [String]
        XCTAssertEqual(warnings?.count, 1)

        let runStateData = try Data(contentsOf: URL(fileURLWithPath: config.modules.mail.state.runStatePath))
        let runStateJSON = try JSONSerialization.jsonObject(with: runStateData) as? [String: Any]
        XCTAssertEqual(runStateJSON?["lastAcceptedRowID"] as? Int, 0)
        let entries = runStateJSON?["entries"] as? [String: Any]
        let entry = try XCTUnwrap(entries?.values.first as? [String: Any])
        XCTAssertEqual(entry["status"] as? String, "submitted")
        let attempts = (entry["attempts"] as? NSNumber)?.intValue ?? (entry["attempts"] as? Int) ?? 0
        XCTAssertEqual(attempts, 1)
        let recordedError = entry["lastError"] ?? entry["last_error"]
        XCTAssertNotNil(recordedError)

        XCTAssertFalse(fm.fileExists(atPath: stateURL.path))
    }

    func testRealRunWithFinalRejectionLogsAndMarksRejected() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        let stateURL = tempRoot.appendingPathComponent("state.json")
        let builder = try MailFixtureBuilder(root: tempRoot)
        let mailbox = try builder.createMailbox(name: "INBOX", displayName: "Inbox")
        try builder.addMessage(mailbox: mailbox, subject: "Rejected", remoteID: "r-1", flags: 0)
        let collector = EmailIndexedCollector(mailRoot: builder.mailRoot, stateFileURL: stateURL)
        let mockCollector = MockEmailCollector()
        await mockCollector.setDocumentSubmissionError(EmailCollectorError.gatewayHTTPError(400, "Bad Request"))
        let (config, stateRoot) = makeConfig(mailEnabled: true)
        defer { try? fm.removeItem(at: stateRoot) }
        let handler = EmailLocalHandler(
            config: config,
            indexedCollector: collector,
            emailCollector: mockCollector
        )
        let requestBody: [String: Any] = ["mode": "real", "limit": 5]
        let requestData = try JSONSerialization.data(withJSONObject: requestBody)
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/collectors/email_local:run",
            headers: ["Content-Type": "application/json"],
            body: requestData
        )
        let response = await handler.handleRun(request: request, context: RequestContext())
        XCTAssertEqual(response.statusCode, 200)
        let payload = try decodeJSONDictionary(from: response.body)
        XCTAssertEqual(payload["status"] as? String, "partial")

        let runStateData = try Data(contentsOf: URL(fileURLWithPath: config.modules.mail.state.runStatePath))
        let runStateJSON = try JSONSerialization.jsonObject(with: runStateData) as? [String: Any]
        XCTAssertEqual(runStateJSON?["lastAcceptedRowID"] as? Int, 0)
        let entries = try XCTUnwrap(runStateJSON?["entries"] as? [String: Any])
        let entry = try XCTUnwrap(entries.values.first as? [String: Any])
        XCTAssertEqual(entry["status"] as? String, "rejected")
        let rejectedAttempts = (entry["attempts"] as? NSNumber)?.intValue ?? (entry["attempts"] as? Int) ?? 0
        XCTAssertEqual(rejectedAttempts, 1)

        XCTAssertFalse(fm.fileExists(atPath: stateURL.path))

        let logFiles = try fm.contentsOfDirectory(at: stateRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix("rejected") && $0.pathExtension == "log" }
        XCTAssertEqual(logFiles.count, 1)
        let logData = try String(contentsOf: logFiles[0])
        let lines = logData.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1)
        let logJSON = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        XCTAssertEqual(logJSON?["attempts"] as? Int, 1)
        XCTAssertEqual(logJSON?["rowID"] as? Int, 1)
    }

    func testRealRunMixedOutcomesAdvancesOnlyAccepted() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        let stateURL = tempRoot.appendingPathComponent("state.json")
        let builder = try MailFixtureBuilder(root: tempRoot)
        let mailbox = try builder.createMailbox(name: "INBOX", displayName: "Inbox")
        try builder.addMessage(mailbox: mailbox, subject: "First", remoteID: "m-1", flags: 0)
        try builder.addMessage(mailbox: mailbox, subject: "Second", remoteID: "m-2", flags: 0)
        let collector = EmailIndexedCollector(mailRoot: builder.mailRoot, stateFileURL: stateURL)
        let mockCollector = MockEmailCollector()
        await mockCollector.setDocumentSubmissionResults([
            .success(()),
            .failure(EmailCollectorError.gatewayHTTPError(502, "Bad Gateway"))
        ])
        let (config, stateRoot) = makeConfig(mailEnabled: true)
        defer { try? fm.removeItem(at: stateRoot) }
        let handler = EmailLocalHandler(
            config: config,
            indexedCollector: collector,
            emailCollector: mockCollector
        )
        let requestBody: [String: Any] = ["mode": "real", "limit": 10]
        let requestData = try JSONSerialization.data(withJSONObject: requestBody)
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/collectors/email_local:run",
            headers: ["Content-Type": "application/json"],
            body: requestData
        )
        let response = await handler.handleRun(request: request, context: RequestContext())
        XCTAssertEqual(response.statusCode, 200)
        let payload = try decodeJSONDictionary(from: response.body)
        XCTAssertEqual(payload["status"] as? String, "partial")

        let runStateData = try Data(contentsOf: URL(fileURLWithPath: config.modules.mail.state.runStatePath))
        let runStateJSON = try JSONSerialization.jsonObject(with: runStateData) as? [String: Any]
        XCTAssertEqual(runStateJSON?["lastAcceptedRowID"] as? Int, 1)
        let entries = try XCTUnwrap(runStateJSON?["entries"] as? [String: Any])
        let acceptedEntry = try XCTUnwrap(entries["1"] as? [String: Any])
        XCTAssertEqual(acceptedEntry["status"] as? String, "accepted")
        let pendingEntry = try XCTUnwrap(entries["2"] as? [String: Any])
        XCTAssertEqual(pendingEntry["status"] as? String, "submitted")

        let stateData = try Data(contentsOf: stateURL)
        let stateJSON = try JSONSerialization.jsonObject(with: stateData) as? [String: Any]
        XCTAssertEqual(stateJSON?["lastRowID"] as? Int, 1)
    }
    
    // MARK: - Helpers
    
    private actor MockEmailCollector: EmailCollecting {
        private(set) var builtPayloadEmails: [EmailMessage] = []
        private(set) var submittedDocuments: [EmailDocumentPayload] = []
        private(set) var submittedAttachments: [(URL, EmailAttachment)] = []
        
        var documentSubmissionError: Error?
        var attachmentSubmissionError: Error?
        var documentSubmissionResults: [Result<Void, Error>] = []

        func setDocumentSubmissionError(_ error: Error?) async {
            documentSubmissionError = error
        }

        func setAttachmentSubmissionError(_ error: Error?) async {
            attachmentSubmissionError = error
        }

        func setDocumentSubmissionResults(_ results: [Result<Void, Error>]) async {
            documentSubmissionResults = results
        }
        
        func buildDocumentPayload(
            email: EmailMessage,
            intent: IntentClassification?,
            relevance: Double?
        ) async throws -> EmailDocumentPayload {
            builtPayloadEmails.append(email)
            let body = email.bodyPlainText ?? email.bodyHTML ?? "(empty email body)"
            let normalized = body
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let contentHash = sha256Hex(normalized)
            let content = EmailDocumentContent(mimeType: "text/plain", data: body, encoding: nil)
            let metadata = EmailDocumentMetadata(
                messageId: email.messageId,
                subject: email.subject,
                snippet: String(body.prefix(120)),
                listUnsubscribe: email.listUnsubscribe,
                headers: email.headers,
                hasAttachments: !email.attachments.isEmpty,
                attachmentCount: email.attachments.count,
                contentHash: contentHash,
                references: email.references,
                inReplyTo: email.inReplyTo,
                intent: nil,
                relevanceScore: relevance
            )
            
            return EmailDocumentPayload(
                sourceType: "email_local",
                sourceId: email.messageId ?? "mock-\(builtPayloadEmails.count)",
                title: email.subject,
                canonicalUri: nil,
                content: content,
                metadata: metadata,
                contentTimestamp: email.date,
                contentTimestampType: "received",
                people: [],
                threadId: nil,
                thread: nil,
                intent: nil,
                relevanceScore: relevance
            )
        }
        
        func submitEmailDocument(_ payload: EmailDocumentPayload) async throws -> GatewaySubmissionResponse {
            if let outcome = documentSubmissionResults.first {
                documentSubmissionResults.removeFirst()
                if case .failure(let customError) = outcome {
                    throw customError
                }
            }
            if let error = documentSubmissionError {
                throw error
            }
            submittedDocuments.append(payload)
            return GatewaySubmissionResponse(
                submissionId: UUID().uuidString,
                docId: UUID().uuidString,
                externalId: payload.sourceId,
                status: "submitted",
                threadId: payload.threadId?.uuidString,
                fileIds: [],
                duplicate: false,
                totalChunks: 1
            )
        }
        
        func submitEmailAttachment(
            fileURL: URL,
            attachment: EmailAttachment,
            messageId: String?,
            intent: IntentClassification?,
            relevance: Double?,
            enrichment: EmailAttachmentEnrichment?
        ) async throws -> GatewayFileSubmissionResponse {
            if let error = attachmentSubmissionError {
                throw error
            }
            submittedAttachments.append((fileURL, attachment))
            return GatewayFileSubmissionResponse(
                submissionId: UUID().uuidString,
                docId: UUID().uuidString,
                externalId: messageId ?? UUID().uuidString,
                status: "submitted",
                threadId: nil,
                fileIds: [],
                duplicate: false,
                totalChunks: 1,
                fileSha256: "mock-sha",
                objectKey: fileURL.lastPathComponent,
                extractionStatus: "pending"
            )
        }
        
        func builtPayloadCount() async -> Int {
            builtPayloadEmails.count
        }
        
        func submittedDocumentCount() async -> Int {
            submittedDocuments.count
        }
        
        func submittedAttachmentCount() async -> Int {
            submittedAttachments.count
        }
        
        private func sha256Hex(_ text: String) -> String {
            let data = Data(text.utf8)
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }
    
    private func makeConfig(mailEnabled: Bool) -> (config: HavenConfig, stateRoot: URL) {
        var config = HavenConfig()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        config.modules.mail = MailModuleConfig(
            enabled: mailEnabled,
            filters: MailFiltersConfig(),
            state: MailStateConfig(
                clearOnNewRun: true,
                runStatePath: root.appendingPathComponent("run_state.json").path,
                rejectedLogPath: root.appendingPathComponent("rejected.log").path,
                lockFilePath: root.appendingPathComponent("lock").path,
                rejectedRetentionDays: 7
            )
        )
        return (config, root)
    }
    
    private func decodeJSONDictionary(from data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
