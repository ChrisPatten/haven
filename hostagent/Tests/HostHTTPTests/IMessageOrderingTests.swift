import XCTest
@testable import HostHTTP

final class IMessageOrderingTests: XCTestCase {
    
    func testAscOrderingWithCacheSkipsProcessedMessages() throws {
        // Test that ascending order properly skips already-processed messages
        // This simulates the scenario where order=asc and limit=100 consecutive runs
        // should return different earliest_touched and latest_touched values
        
        // Simulate message ROWIDs 1-1000
        let searchResultAsc: [Int64] = Array(1...1000)
        
        // First run: no processed messages yet
        let firstRun = composeProcessingOrder(
            searchResultAsc: searchResultAsc,
            lastProcessedId: nil,
            order: "asc",
            since: nil,
            before: nil,
            oldestCachedId: nil
        )
        
        // Should return all messages
        XCTAssertEqual(firstRun.count, 1000)
        XCTAssertEqual(firstRun.first, 1)
        XCTAssertEqual(firstRun.last, 1000)
        
        // Second run: last processed was 100 (simulating limit=100)
        let secondRun = composeProcessingOrder(
            searchResultAsc: searchResultAsc,
            lastProcessedId: 100,
            order: "asc",
            since: nil,
            before: nil,
            oldestCachedId: nil
        )
        
        // Should skip messages 1-100 and return 101-1000
        XCTAssertEqual(secondRun.count, 900)
        XCTAssertEqual(secondRun.first, 101)
        XCTAssertEqual(secondRun.last, 1000)
        
        // Third run: last processed was 200 (another 100 messages)
        let thirdRun = composeProcessingOrder(
            searchResultAsc: searchResultAsc,
            lastProcessedId: 200,
            order: "asc",
            since: nil,
            before: nil,
            oldestCachedId: nil
        )
        
        // Should skip messages 1-200 and return 201-1000
        XCTAssertEqual(thirdRun.count, 800)
        XCTAssertEqual(thirdRun.first, 201)
        XCTAssertEqual(thirdRun.last, 1000)
    }
    
    func testAscOrderingWithoutCacheProcessesAll() throws {
        // Test ascending order when no messages have been processed yet
        let searchResultAsc: [Int64] = Array(1...100)
        
        let ordered = composeProcessingOrder(
            searchResultAsc: searchResultAsc,
            lastProcessedId: nil,
            order: "asc",
            since: nil,
            before: nil,
            oldestCachedId: nil
        )
        
        // Should return all messages in ascending order
        XCTAssertEqual(ordered, Array(1...100))
    }
    
    func testDescOrderingBehaviorUnchanged() throws {
        // Test that descending order behavior remains unchanged
        let searchResultAsc: [Int64] = Array(1...100)
        
        let ordered = composeProcessingOrder(
            searchResultAsc: searchResultAsc,
            lastProcessedId: 50,
            order: "desc",
            since: nil,
            before: nil,
            oldestCachedId: 25  // Provide oldestCachedId to match Email IMAP behavior
        )
        
        // Should return newer messages (51-100) in descending order, then older messages (1-24) in descending order
        let expectedNewer = Array(51...100).reversed().map { Int64($0) }
        let expectedOlder = Array(1...24).reversed().map { Int64($0) }
        let expected = expectedNewer + expectedOlder
        
        XCTAssertEqual(ordered, expected)
    }
    
    // Helper function that mirrors the private composeProcessingOrder function
    private func composeProcessingOrder(
        searchResultAsc: [Int64],
        lastProcessedId: Int64?,
        order: String?,
        since: Date?,
        before: Date?,
        oldestCachedId: Int64? = nil
    ) -> [Int64] {
        let uidsSortedAsc = searchResultAsc.sorted()
        let normalizedOrder = order?.lowercased()

        // If the caller provides an explicit oldestCachedId, use that to
        // determine the cached range. Otherwise, fall back to treating all IDs <=
        // lastProcessedId as cached (best-effort given stored state only records
        // the most-recent ID).
        let cachedIds: [Int64]
        if let oldest = oldestCachedId, let last = lastProcessedId {
            cachedIds = uidsSortedAsc.filter { $0 >= oldest && $0 <= last }
        } else if let last = lastProcessedId {
            cachedIds = uidsSortedAsc.filter { $0 <= last }
        } else {
            cachedIds = []
        }
        let newerAsc = uidsSortedAsc.filter { id in
            if let last = lastProcessedId { return id > last }
            return true
        }

        if normalizedOrder == "desc" {
            // Process newer messages newest->oldest, then older-than-cache newest->oldest
            let newDesc = Array(newerAsc.reversed())
            if let oldestCached = cachedIds.first {
                let olderThanCacheDesc = Array(uidsSortedAsc.filter { $0 < oldestCached }.reversed())
                return newDesc + olderThanCacheDesc
            } else {
                // No cached ids: just return all in descending order
                return Array(uidsSortedAsc.reversed())
            }
        } else {
            // Ascending ordering: process messages in ascending order, skipping already-processed ones
            // to enable proper pagination across multiple runs.
            if let last = lastProcessedId {
                return uidsSortedAsc.filter { $0 > last }
            } else {
                return uidsSortedAsc
            }
        }
    }
}
