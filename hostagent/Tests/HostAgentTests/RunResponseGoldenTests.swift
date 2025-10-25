import XCTest
@testable import HostAgent

final class RunResponseGoldenTests: XCTestCase {
    func testRunResponseGoldenSerialization() throws {
        var resp = RunResponse(collector: "email_imap", runID: "test-run", startedAt: Date())
        // Make the payload deterministic for the golden
        resp.started_at = "2025-10-25T00:00:00Z"
        resp.finished_at = "2025-10-25T00:00:05Z"
        resp.status = .ok
        resp.stats = RunResponse.Stats(scanned: 10, matched: 9, submitted: 7, skipped: 2, earliest_touched: "2025-10-24T00:00:00Z", latest_touched: "2025-10-25T00:00:00Z", batches: 1)
        resp.warnings = ["w1"]
        resp.errors = ["e1"]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(resp)

        // Load golden fixture
        let bundle = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let fixtureURL = bundle.appendingPathComponent("Fixtures/runresponse_golden.json")
        let golden = try Data(contentsOf: fixtureURL)

        XCTAssertEqual(data, golden, "RunResponse JSON must match the golden fixture")
    }
}
