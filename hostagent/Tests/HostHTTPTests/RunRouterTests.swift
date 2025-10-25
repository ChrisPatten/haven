import XCTest
import HavenCore
@testable import HostHTTP
@testable import HostAgentEmail

final class RunRouterTests: XCTestCase {
    func testRejectsUnknownJSONFields() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["unexpected_field": 1])
        let req = HTTPRequest(method: "POST", path: "/v1/collectors/email_local:run", headers: ["Content-Type": "application/json"], body: body)
        let dispatch: [String: (HTTPRequest, RequestContext) async -> HTTPResponse] = [
            "email_local": { _, _ in
                return HTTPResponse.ok(json: ["status": "completed"])
            }
        ]

        let resp = await RunRouter.handle(request: req, context: RequestContext(), dispatchMap: dispatch)
        XCTAssertEqual(resp.statusCode, 400)
        let payload = try decodeJSONDictionary(from: resp.body)
        XCTAssertNotNil(payload["error"])
    }

    func testUnknownCollectorReturns404() async throws {
        let body = try JSONSerialization.data(withJSONObject: [:])
        let req = HTTPRequest(method: "POST", path: "/v1/collectors/nope:run", headers: ["Content-Type": "application/json"], body: body)
        let dispatch: [String: (HTTPRequest, RequestContext) async -> HTTPResponse] = [:]

        let resp = await RunRouter.handle(request: req, context: RequestContext(), dispatchMap: dispatch)
        XCTAssertEqual(resp.statusCode, 404)
        let payload = try decodeJSONDictionary(from: resp.body)
        XCTAssertNotNil(payload["error"])
    }

    func testValidRequestDispatchesAndWrapped() async throws {
        var called = false
        let body = try JSONSerialization.data(withJSONObject: [:])
        let req = HTTPRequest(method: "POST", path: "/v1/collectors/imessage:run", headers: ["Content-Type": "application/json"], body: body)
        let dispatch: [String: (HTTPRequest, RequestContext) async -> HTTPResponse] = [
            "imessage": { _, _ in
                called = true
                return HTTPResponse.ok(json: ["status": "completed"]) 
            }
        ]

        let resp = await RunRouter.handle(request: req, context: RequestContext(), dispatchMap: dispatch)
        XCTAssertEqual(resp.statusCode, 200)
        let payload = try decodeJSONDictionary(from: resp.body)
        XCTAssertEqual(payload["collector"] as? String, "imessage")
        XCTAssertEqual(payload["inner_status_code"] as? Int, 200)
        XCTAssertTrue(called)
    }

    // Helper to decode JSON data produced by RunRouter
    private func decodeJSONDictionary(from data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }
}
