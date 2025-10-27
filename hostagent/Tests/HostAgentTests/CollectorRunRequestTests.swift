import XCTest
@testable import HostAgentEmail

final class CollectorRunRequestTests: XCTestCase {

    func testConcurrencyClamping() throws {
        // Test clamping value < 1 to 1
        let jsonZero = #"{"concurrency": 0}"#
        let dataZero = jsonZero.data(using: .utf8)!
        let decoder = JSONDecoder()
        let reqZero = try decoder.decode(CollectorRunRequest.self, from: dataZero)
        XCTAssertEqual(reqZero.concurrency, 1, "Concurrency 0 should be clamped to 1")

        let jsonNegative = #"{"concurrency": -5}"#
        let dataNegative = jsonNegative.data(using: .utf8)!
        let reqNegative = try decoder.decode(CollectorRunRequest.self, from: dataNegative)
        XCTAssertEqual(reqNegative.concurrency, 1, "Concurrency -5 should be clamped to 1")

        // Test clamping value > 12 to 12
        let jsonHigh = #"{"concurrency": 20}"#
        let dataHigh = jsonHigh.data(using: .utf8)!
        let reqHigh = try decoder.decode(CollectorRunRequest.self, from: dataHigh)
        XCTAssertEqual(reqHigh.concurrency, 12, "Concurrency 20 should be clamped to 12")

        let jsonVeryHigh = #"{"concurrency": 100}"#
        let dataVeryHigh = jsonVeryHigh.data(using: .utf8)!
        let reqVeryHigh = try decoder.decode(CollectorRunRequest.self, from: dataVeryHigh)
        XCTAssertEqual(reqVeryHigh.concurrency, 12, "Concurrency 100 should be clamped to 12")

        // Test valid values remain unchanged
        let jsonValidLow = #"{"concurrency": 1}"#
        let dataValidLow = jsonValidLow.data(using: .utf8)!
        let reqValidLow = try decoder.decode(CollectorRunRequest.self, from: dataValidLow)
        XCTAssertEqual(reqValidLow.concurrency, 1, "Concurrency 1 should remain 1")

        let jsonValidMid = #"{"concurrency": 6}"#
        let dataValidMid = jsonValidMid.data(using: .utf8)!
        let reqValidMid = try decoder.decode(CollectorRunRequest.self, from: dataValidMid)
        XCTAssertEqual(reqValidMid.concurrency, 6, "Concurrency 6 should remain 6")

        let jsonValidHigh = #"{"concurrency": 12}"#
        let dataValidHigh = jsonValidHigh.data(using: .utf8)!
        let reqValidHigh = try decoder.decode(CollectorRunRequest.self, from: dataValidHigh)
        XCTAssertEqual(reqValidHigh.concurrency, 12, "Concurrency 12 should remain 12")

        // Test nil concurrency remains nil
        let jsonNoConcurrency = #"{"mode": "simulate"}"#
        let dataNoConcurrency = jsonNoConcurrency.data(using: .utf8)!
        let reqNoConcurrency = try decoder.decode(CollectorRunRequest.self, from: dataNoConcurrency)
        XCTAssertNil(reqNoConcurrency.concurrency, "Missing concurrency should remain nil")
    }

    func testConcurrencyClampingWithOtherFields() throws {
        // Test clamping works when other fields are present
        let json = #"{"mode": "real", "concurrency": 15, "limit": 100}"#
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let req = try decoder.decode(CollectorRunRequest.self, from: data)

        XCTAssertEqual(req.mode, .real)
        XCTAssertEqual(req.concurrency, 12, "Concurrency 15 should be clamped to 12")
        XCTAssertEqual(req.limit, 100)
    }
}