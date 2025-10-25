import XCTest
@testable import HostAgent

final class IMessageRunAdapterTests: XCTestCase {
    func iso8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    func testDateRangePrecedenceAndOrderDefault() throws {
        let json = #"{ "date_range": { "since": "2025-01-01T00:00:00Z", "until": "2025-01-02T00:00:00Z" } }"#
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let req = try decoder.decode(CollectorRunRequest.self, from: data)

        let mapped = IMessageRunAdapter.toIMessageRequest(req)

        XCTAssertEqual(mapped.order, CollectorRunRequest.Order.desc)
        XCTAssertEqual(mapped.batchSize, 500)
        XCTAssertEqual(mapped.threadLookbackDays, 90)

        let expectedSince = iso8601("2025-01-01T00:00:00Z")
        let expectedUntil = iso8601("2025-01-02T00:00:00Z")
        XCTAssertNotNil(expectedSince)
        XCTAssertNotNil(expectedUntil)
        XCTAssertEqual(mapped.since?.timeIntervalSince1970, expectedSince!.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(mapped.until?.timeIntervalSince1970, expectedUntil!.timeIntervalSince1970, accuracy: 0.001)
    }

    func testTimeWindowFallbackAndConcurrencyClampAndDryRun() throws {
        // Use a deterministic 'now' to assert since computation
        let now = Date(timeIntervalSince1970: 1_700_000_000) // arbitrary fixed time
        let json = #"{ "time_window": 30, "concurrency": 20, "mode": "simulate" }"#
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let req = try decoder.decode(CollectorRunRequest.self, from: data)

        let mapped = IMessageRunAdapter.toIMessageRequest(req, now: now)

        // since should be now - 30 days
        let expectedSince = Calendar(identifier: .gregorian).date(byAdding: .day, value: -30, to: now)!
        XCTAssertEqual(mapped.since?.timeIntervalSince1970, expectedSince.timeIntervalSince1970, accuracy: 1.0)

        // concurrency should be clamped to 12
        XCTAssertEqual(mapped.concurrency, 12)

        // dryRun should be true when mode is simulate
        XCTAssertTrue(mapped.dryRun)
    }
}
