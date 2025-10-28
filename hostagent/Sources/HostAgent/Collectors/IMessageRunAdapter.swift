import Foundation
import HavenCore

// Adapter output type for iMessage runs
public struct IMessageRunRequest: Codable {
    public let since: Date?
    public let until: Date?
    public let order: CollectorRunRequest.Order
    public let threadLookbackDays: Int
    public let concurrency: Int
    public let dryRun: Bool
    public let limit: Int?

    public init(since: Date?, until: Date?, order: CollectorRunRequest.Order, threadLookbackDays: Int, concurrency: Int, dryRun: Bool, limit: Int?) {
        self.since = since
        self.until = until
        self.order = order
        self.threadLookbackDays = threadLookbackDays
        self.concurrency = concurrency
        self.dryRun = dryRun
        self.limit = limit
    }
}

/// Maps the unified CollectorRunRequest DTO into an iMessage-specific run request.
public struct IMessageRunAdapter {
    // Defaults chosen to match existing iMessage collector behaviour
    private static let defaultThreadLookbackDays = 90
    private static let minConcurrency = 1
    private static let maxConcurrency = 12

    /// Map a `CollectorRunRequest` to `IMessageRunRequest`.
    /// - Parameters:
    ///   - dto: the decoded unified DTO
    ///   - now: injection point for tests/time calculations (defaults to `Date()`).
    public static func toIMessageRequest(_ dto: CollectorRunRequest, now: Date = Date()) -> IMessageRunRequest {
        // Order: default to desc when not provided
        let order = dto.order ?? .desc

        // Date precedence: date_range overrides time_window
        var since: Date? = nil
        var until: Date? = nil
        let threadLookbackDays = defaultThreadLookbackDays

        if let dr = dto.dateRange {
            // Use explicit date_range values (may be nil individually)
            since = dr.since
            until = dr.until
            // When an explicit date_range is provided we keep threadLookbackDays as default
        } else if let lookbackDays = dto.timeWindow {
            // compute since = now - lookbackDays
            since = Calendar(identifier: .gregorian).date(byAdding: .day, value: -lookbackDays, to: now)
            until = nil
            // thread lookback not present on the unified DTO - keep default
        }

        // concurrency already clamped when decoding CollectorRunRequest, but ensure default
        let concurrency = dto.concurrency ?? minConcurrency

        // dryRun semantics: map mode.simulate -> true
        let dryRun = dto.mode == .simulate

        let limit = dto.limit

        return IMessageRunRequest(
            since: since,
            until: until,
            order: order,
            threadLookbackDays: threadLookbackDays,
            concurrency: concurrency,
            dryRun: dryRun,
            limit: limit
        )
    }
}
