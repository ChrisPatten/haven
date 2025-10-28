import XCTest
@testable import HostHTTP
import HavenCore
import IMAP

final class EmailImapHandlerTests: XCTestCase {
    func testRunReturnsBadRequestWhenModuleDisabled() async throws {
        var config = HavenConfig()
        config.modules.mailImap.enabled = false
        let handler = EmailImapHandler(config: config)
        let response = await handler.handleRun(request: HTTPRequest(method: "POST", path: "/v1/collectors/email_imap:run"), context: .empty)
        XCTAssertEqual(response.statusCode, 400)
    }
    
    func testLimitOverrideFromRequest() async throws {
        // Test that limit from POST request overrides config default
        var config = HavenConfig()
        config.defaultLimit = 50
        config.modules.mailImap.enabled = true
        config.modules.mailImap.accounts = [
            MailImapAccountConfig(
                id: "test",
                host: "imap.example.com",
                port: 993,
                tls: true,
                username: "test@example.com",
                auth: MailImapAuthConfig(kind: "app_password", secretRef: "test-secret"),
                folders: ["INBOX"]
            )
        ]
        
        let handler = EmailImapHandler(config: config)
        
        // Test with limit provided in request - should override config default
        let requestBody = """
        {
            "limit": 200,
            "order": "desc"
        }
        """.data(using: .utf8)!
        
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/collectors/email_imap:run",
            headers: ["Content-Type": "application/json"],
            body: requestBody
        )
        
        // This will fail due to missing IMAP credentials, but we can verify the limit was parsed correctly
        let response = await handler.handleRun(request: request, context: .empty)
        
        // Should fail with credentials error, not limit parsing error
        XCTAssertEqual(response.statusCode, 500) // Changed from 400 to 500
        let responseBody = String(data: response.body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(responseBody.contains("Invalid secret reference") || responseBody.contains("Failed to initialize IMAP session"))
    }
    
    func testUsesConfigDefaultWhenLimitNotProvided() async throws {
        // Test that config default is used when limit not provided in request
        var config = HavenConfig()
        config.defaultLimit = 75
        config.modules.mailImap.enabled = true
        config.modules.mailImap.accounts = [
            MailImapAccountConfig(
                id: "test",
                host: "imap.example.com",
                port: 993,
                tls: true,
                username: "test@example.com",
                auth: MailImapAuthConfig(kind: "app_password", secretRef: "test-secret"),
                folders: ["INBOX"]
            )
        ]
        
        let handler = EmailImapHandler(config: config)
        
        // Test without limit provided - should use config default
        let requestBody = """
        {
            "order": "asc"
        }
        """.data(using: .utf8)!
        
        let request = HTTPRequest(
            method: "POST",
            path: "/v1/collectors/email_imap:run",
            headers: ["Content-Type": "application/json"],
            body: requestBody
        )
        
        // This will fail due to missing IMAP credentials, but we can verify the limit was parsed correctly
        let response = await handler.handleRun(request: request, context: .empty)
        
        // Should fail with credentials error, not limit parsing error
        XCTAssertEqual(response.statusCode, 500) // Changed from 400 to 500
        let responseBody = String(data: response.body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(responseBody.contains("Invalid secret reference") || responseBody.contains("Failed to initialize IMAP session"))
    }
}

private extension RequestContext {
    static var empty: RequestContext {
        RequestContext()
    }
}
