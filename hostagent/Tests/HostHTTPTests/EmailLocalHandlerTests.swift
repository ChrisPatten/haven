import XCTest
@testable import HostHTTP
import HavenCore

final class EmailLocalHandlerTests: XCTestCase {
    func testSimulateRunProcessesFixtureAndUpdatesState() async throws {
        let handler = EmailLocalHandler(config: makeConfig(mailEnabled: true))
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
    }
    
    func testRunRejectedWhenModuleDisabled() async throws {
        let handler = EmailLocalHandler(config: makeConfig(mailEnabled: false))
        let request = HTTPRequest(method: "POST", path: "/v1/collectors/email_local:run")
        
        let response = await handler.handleRun(request: request, context: RequestContext())
        XCTAssertEqual(response.statusCode, 503)
        
        let payload = try decodeJSONDictionary(from: response.body)
        XCTAssertEqual(payload["error"] as? String, "Email collector module is disabled")
    }
    
    func testConcurrentRunReturnsConflict() async throws {
        let handler = EmailLocalHandler(config: makeConfig(mailEnabled: true))
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
        let handler = EmailLocalHandler(config: makeConfig(mailEnabled: true))
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
        let handler = EmailLocalHandler(config: makeConfig(mailEnabled: true), indexedCollector: collector)
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
    }
    
    func testRealRunFallsBackWhenEnvelopeMissing() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        let collector = EmailIndexedCollector(mailRoot: tempRoot, stateFileURL: tempRoot.appendingPathComponent("state.json"))
        let handler = EmailLocalHandler(config: makeConfig(mailEnabled: true), indexedCollector: collector)
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
    
    // MARK: - Helpers
    
    private func makeConfig(mailEnabled: Bool) -> HavenConfig {
        var config = HavenConfig()
        config.modules.mail = MailModuleConfig(enabled: mailEnabled)
        return config
    }
    
    private func decodeJSONDictionary(from data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
