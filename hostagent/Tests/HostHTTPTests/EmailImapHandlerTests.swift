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
}

private extension RequestContext {
    static var empty: RequestContext {
        RequestContext()
    }
}
