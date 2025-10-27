import XCTest
@testable import HostHTTP

final class EmailImapOrderingTests: XCTestCase {
    func testDescOrderingWithCacheProcessesNewerThenOlder() throws {
        // Server UIDs 0..100
        let search: [UInt32] = Array(0...100).map { UInt32($0) }
        // Cached range 75..85 -> lastProcessedUid = 85
        let lastProcessed: UInt32 = 85

        let ordered = EmailImapHandler.composeProcessingOrder(
            searchResultAsc: search,
            lastProcessedUid: lastProcessed,
            order: "desc",
            since: nil,
            before: nil,
            oldestCachedUid: 75
        )

        // Expect: 100..86 then 74..0
        let expectedNewerDesc = Array((86...100).reversed()).map { UInt32($0) }
        let expectedOlderDesc = Array((0...74).reversed()).map { UInt32($0) }
        let expected = expectedNewerDesc + expectedOlderDesc

        XCTAssertEqual(ordered, expected)
    }

    func testAscOrderingWithCacheProcessesOlderThenNewer() throws {
        let search: [UInt32] = Array(0...100).map { UInt32($0) }
        let lastProcessed: UInt32 = 85

        let ordered = EmailImapHandler.composeProcessingOrder(
            searchResultAsc: search,
            lastProcessedUid: lastProcessed,
            order: "asc",
            since: nil,
            before: nil,
            oldestCachedUid: 75
        )

        // Expect: 0..74 then 86..100
        let expectedOlderAsc = Array(0...74).map { UInt32($0) }
        let expectedNewerAsc = Array(86...100).map { UInt32($0) }
        let expected = expectedOlderAsc + expectedNewerAsc

        XCTAssertEqual(ordered, expected)
    }
}
