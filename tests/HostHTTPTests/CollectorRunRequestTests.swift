import XCTest
@testable import HostAgentEmail

final class CollectorRunRequestTests: XCTestCase {
    func testRejectsUnknownFields() throws {
        let json = "{\"mode\": \"real\", \"limit\": 10, \"unknown_field\": \"boom\"}"
        let data = Data(json.utf8)
        let decoder = JSONDecoder()

        XCTAssertThrowsError(try decoder.decode(CollectorRunRequest.self, from: data)) { error in
            if case DecodingError.dataCorrupted = error { /* good */ } else {
                XCTFail("Expected dataCorrupted, got: \(error)")
            }
        }
    }

    func testConcurrencyClamped() throws {
        let json = "{\"concurrency\": 20}"
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        let req = try decoder.decode(CollectorRunRequest.self, from: data)
        XCTAssertEqual(req.concurrency, 12)
    }

    func testDateRangePrecedenceOverTimeWindow() throws {
        let since = "2023-01-01T00:00:00Z"
        let until = "2023-02-01T00:00:00Z"
        let dict: [String: Any] = [
            "date_range": ["since": since, "until": until],
            "time_window": 3600
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        let req = try decoder.decode(CollectorRunRequest.self, from: data)
        XCTAssertNotNil(req.dateRange)
        XCTAssertEqual(req.timeWindow, 3600)
        XCTAssertNotNil(req.dateRange?.since)
        XCTAssertNotNil(req.dateRange?.until)
    }
}
