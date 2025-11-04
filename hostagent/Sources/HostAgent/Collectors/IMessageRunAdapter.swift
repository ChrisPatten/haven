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

    /// Parse ISO-8601 duration string (e.g., "PT24H", "P1D") to TimeInterval in seconds
    private static func parseISO8601Duration(_ duration: String) -> TimeInterval? {
        // ISO-8601 duration format: P[n]Y[n]M[n]DT[n]H[n]M[n]S
        // Examples: "PT24H" (24 hours), "P1D" (1 day), "P7D" (7 days)
        var durationStr = duration.trimmingCharacters(in: .whitespaces)
        guard durationStr.hasPrefix("P") else { return nil }
        
        var totalSeconds: TimeInterval = 0
        durationStr = String(durationStr.dropFirst()) // Remove "P"
        
        // Split date and time parts
        let parts = durationStr.split(separator: "T", maxSplits: 1)
        let datePart = parts[0]
        let timePart = parts.count > 1 ? String(parts[1]) : ""
        
        // Parse date part (Y, M, D)
        var currentNumber = ""
        for char in datePart {
            if char.isNumber {
                currentNumber.append(char)
            } else {
                if let value = Double(currentNumber) {
                    switch char {
                    case "Y":
                        totalSeconds += value * 365.25 * 24 * 3600 // Years
                    case "M":
                        totalSeconds += value * 30.44 * 24 * 3600 // Months (average)
                    case "D":
                        totalSeconds += value * 24 * 3600 // Days
                    default:
                        return nil
                    }
                }
                currentNumber = ""
            }
        }
        
        // Parse time part (H, M, S)
        currentNumber = ""
        for char in timePart {
            if char.isNumber {
                currentNumber.append(char)
            } else {
                if let value = Double(currentNumber) {
                    switch char {
                    case "H":
                        totalSeconds += value * 3600 // Hours
                    case "M":
                        totalSeconds += value * 60 // Minutes
                    case "S":
                        totalSeconds += value // Seconds
                    default:
                        return nil
                    }
                }
                currentNumber = ""
            }
        }
        
        return totalSeconds > 0 ? totalSeconds : nil
    }

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
        } else if let timeWindow = dto.timeWindow {
            // Parse ISO-8601 duration and compute since = now - duration
            if let durationSeconds = parseISO8601Duration(timeWindow) {
                since = now.addingTimeInterval(-durationSeconds)
            }
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
