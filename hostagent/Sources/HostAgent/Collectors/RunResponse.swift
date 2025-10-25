import Foundation

/// Standard RunResponse envelope returned by collector run endpoints.
///
/// Conforms to the documented standard JSON response:
/// {
///   "status": "ok|error|partial",
///   "collector": "...",
///   "run_id": "...",
///   "started_at": "...",
///   "finished_at": "...",
///   "stats": { ... },
///   "warnings": [],
///   "errors": []
/// }
public struct RunResponse: Codable {
    public enum Status: String, Codable {
        case ok
        case error
        case partial
    }

    public var status: Status
    public var collector: String
    public var run_id: String
    public var started_at: String
    public var finished_at: String?
    public var stats: Stats
    public var warnings: [String]
    public var errors: [String]

    // Non-encoded runtime helper to compute durations.
    private var startDate: Date?

    public struct Stats: Codable {
        public var scanned: Int
        public var matched: Int
        public var submitted: Int
        public var skipped: Int
        public var earliest_touched: String?
        public var latest_touched: String?
        public var batches: Int

        public init(scanned: Int = 0, matched: Int = 0, submitted: Int = 0, skipped: Int = 0, earliest_touched: String? = nil, latest_touched: String? = nil, batches: Int = 0) {
            self.scanned = scanned
            self.matched = matched
            self.submitted = submitted
            self.skipped = skipped
            self.earliest_touched = earliest_touched
            self.latest_touched = latest_touched
            self.batches = batches
        }
    }

    public init(collector: String, runID: String, startedAt: Date = Date()) {
        self.status = .ok
        self.collector = collector
        self.run_id = runID
        self.startDate = startedAt
        self.started_at = RunResponse.iso8601UTC(startedAt)
        self.finished_at = nil
        self.stats = Stats()
        self.warnings = []
        self.errors = []
    }

    // MARK: - Helpers

    /// ISO-8601 UTC formatter for timestamps used in the envelope.
    public static func iso8601UTC(_ date: Date = Date()) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    /// Finish the run, set finished_at, and return the duration in seconds (if start was available).
    @discardableResult
    public mutating func finish(status: Status = .ok, finishedAt: Date = Date()) -> TimeInterval? {
        self.finished_at = RunResponse.iso8601UTC(finishedAt)
        self.status = status
        guard let start = startDate else { return nil }
        return finishedAt.timeIntervalSince(start)
    }

    /// Increment batch counters and accumulate per-batch stats. Also updates earliest/latest touched timestamps.
    public mutating func incrementBatch(scanned: Int = 0, matched: Int = 0, submitted: Int = 0, skipped: Int = 0, earliestTouched: Date? = nil, latestTouched: Date? = nil) {
        stats.batches += 1
        stats.scanned += scanned
        stats.matched += matched
        stats.submitted += submitted
        stats.skipped += skipped

        if let et = earliestTouched {
            let s = RunResponse.iso8601UTC(et)
            if let prev = stats.earliest_touched {
                if s < prev { stats.earliest_touched = s }
            } else {
                stats.earliest_touched = s
            }
        }

        if let lt = latestTouched {
            let s = RunResponse.iso8601UTC(lt)
            if let prev = stats.latest_touched {
                if s > prev { stats.latest_touched = s }
            } else {
                stats.latest_touched = s
            }
        }
    }

    // MARK: - Adapter integration helper

    /// A minimal protocol adapters can adopt to allow conversion of adapter-specific run results into
    /// the RunResponse envelope. Adapters should supply counts and optional touched timestamps.
    public protocol AdapterResult {
        var scanned: Int { get }
        var matched: Int { get }
        var submitted: Int { get }
        var skipped: Int { get }
        var earliestTouched: Date? { get }
        var latestTouched: Date? { get }
        var warnings: [String] { get }
        var errors: [String] { get }
    }

    /// Incorporate an adapter's result as another batch into the response.
    public mutating func incorporateAdapterResult(_ r: AdapterResult) {
        incrementBatch(scanned: r.scanned, matched: r.matched, submitted: r.submitted, skipped: r.skipped, earliestTouched: r.earliestTouched, latestTouched: r.latestTouched)
        self.warnings.append(contentsOf: r.warnings)
        self.errors.append(contentsOf: r.errors)
    }
}
