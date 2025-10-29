import Foundation
import HavenCore



// DTO for collector run requests. Strict decoding: unknown fields cause a decoding error.
public struct CollectorRunRequest: Codable {
    private static let logger = HavenLogger(category: "collector-run-request")
    public enum Mode: String, Codable {
        case simulate
        case real
    }

    public enum Order: String, Codable {
        case asc
        case desc
    }

    public struct DateRange: Codable {
        public let since: Date?
        public let until: Date?

        enum CodingKeys: String, CodingKey {
            case since
            case until
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let sinceStr = try container.decodeIfPresent(String.self, forKey: .since) {
                self.since = CollectorRunRequest.parseISO8601(sinceStr)
            } else { self.since = nil }
            if let untilStr = try container.decodeIfPresent(String.self, forKey: .until) {
                self.until = CollectorRunRequest.parseISO8601(untilStr)
            } else { self.until = nil }
            // unknown keys check for date_range
            let allKeys = Set(container.allKeys.map { $0.stringValue })
            let allowed: Set<String> = ["since", "until"]
            let unknown = allKeys.subtracting(allowed)
            if !unknown.isEmpty {
                throw DecodingError.dataCorruptedError(forKey: CodingKeys.since, in: container, debugDescription: "Unknown keys in date_range: \(unknown)")
            }
        }
    }

    public let mode: Mode?
    public let limit: Int?
    public let order: Order?
    /// concurrency is clamped to 1..12 when present
    public let concurrency: Int?
    public let dateRange: DateRange?
    public let timeWindow: Int?
    public let batch: Bool?
    public let batchSize: Int?

    enum CodingKeys: String, CodingKey {
        case mode
        case limit
        case order
        case concurrency
        case dateRange = "date_range"
        case timeWindow = "time_window"
        case batch
        case batchSize = "batch_size"
    }

    // Helper dynamic key type to detect unknown fields at top level
    struct DynamicKey: CodingKey, Hashable {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { return nil }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        // Detect unknown keys at top-level
        let container = try decoder.container(keyedBy: DynamicKey.self)
        let providedKeys = Set(container.allKeys.map { $0.stringValue })
    // Allow a top-level `collector_options` object so collector-specific
    // options can be provided without failing strict validation. Individual
    // collectors may parse and apply options from this object.
    let allowedKeys: Set<String> = ["mode", "limit", "order", "concurrency", "date_range", "time_window", "batch", "batch_size", "collector_options"]
        let unknown = providedKeys.subtracting(allowedKeys)
        if !unknown.isEmpty {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown keys: \(unknown)"))
        }

        // Now decode proper fields using strongly-typed container
        let keyed = try decoder.container(keyedBy: CodingKeys.self)

        if let modeStr = try keyed.decodeIfPresent(String.self, forKey: .mode) {
            self.mode = Mode(rawValue: modeStr.lowercased())
        } else {
            self.mode = nil
        }

        self.limit = try keyed.decodeIfPresent(Int.self, forKey: .limit)

        if let orderStr = try keyed.decodeIfPresent(String.self, forKey: .order) {
            self.order = Order(rawValue: orderStr.lowercased())
        } else {
            self.order = nil
        }

        if let conc = try keyed.decodeIfPresent(Int.self, forKey: .concurrency) {
            let original = conc
            // clamp to 1..12
            let clamped = max(1, min(12, conc))
            if clamped != original {
                Self.logger.warning("Concurrency value \(original) out of range, clamped to \(clamped)")
            }
            self.concurrency = clamped
        } else {
            self.concurrency = nil
        }

        if keyed.contains(.dateRange) {
            self.dateRange = try keyed.decodeIfPresent(DateRange.self, forKey: .dateRange)
        } else {
            self.dateRange = nil
        }

        self.timeWindow = try keyed.decodeIfPresent(Int.self, forKey: .timeWindow)

        self.batch = try keyed.decodeIfPresent(Bool.self, forKey: .batch)

        if let decodedBatchSize = try keyed.decodeIfPresent(Int.self, forKey: .batchSize) {
            guard decodedBatchSize > 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .batchSize,
                    in: keyed,
                    debugDescription: "batch_size must be greater than zero"
                )
            }
            self.batchSize = decodedBatchSize
        } else {
            self.batchSize = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(mode?.rawValue, forKey: .mode)
        try container.encodeIfPresent(limit, forKey: .limit)
        try container.encodeIfPresent(order?.rawValue, forKey: .order)
        try container.encodeIfPresent(concurrency, forKey: .concurrency)
        try container.encodeIfPresent(dateRange, forKey: .dateRange)
        try container.encodeIfPresent(timeWindow, forKey: .timeWindow)
        try container.encodeIfPresent(batch, forKey: .batch)
        try container.encodeIfPresent(batchSize, forKey: .batchSize)
    }

    // ISO8601 parsing helper used by nested types
    static func parseISO8601(_ s: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: s) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: s)
    }
}
