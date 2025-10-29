import Foundation

/// Shared fence management for collectors
/// Fences track ranges of timestamps that have been successfully processed
/// to avoid reprocessing the same messages across runs
public struct FenceRange: Codable, Equatable {
    public let earliest: Date
    public let latest: Date
    
    public init(earliest: Date, latest: Date) {
        self.earliest = earliest
        self.latest = latest
    }
    
    /// Check if a timestamp falls within this fence range (inclusive boundaries)
    /// Uses a small epsilon (1ms) to handle floating-point precision issues
    public func contains(_ timestamp: Date) -> Bool {
        // Use inclusive boundaries: timestamp is in fence if it's >= earliest and <= latest
        // Add small epsilon for boundary comparisons to handle floating-point precision issues
        // Messages within 1 millisecond of boundary are considered on boundary (inclusive)
        let epsilon: TimeInterval = 0.001 // 1 millisecond
        let adjustedEarliest = earliest.addingTimeInterval(-epsilon)
        let adjustedLatest = latest.addingTimeInterval(epsilon)
        return timestamp >= adjustedEarliest && timestamp <= adjustedLatest
    }
    
    /// Check if this fence overlaps with another fence
    public func overlaps(with other: FenceRange) -> Bool {
        return earliest <= other.latest && latest >= other.earliest
    }
    
    /// Check if this fence is contiguous with another (overlaps or adjacent within 1 second)
    public func isContiguous(with other: FenceRange) -> Bool {
        // Two ranges are contiguous if they overlap or are adjacent (within 1 second)
        if overlaps(with: other) {
            return true
        }
        let gap = min(abs(latest.timeIntervalSince(other.earliest)), abs(earliest.timeIntervalSince(other.latest)))
        return gap <= 1.0
    }
    
    /// Merge this fence with another to create a combined range
    public func merged(with other: FenceRange) -> FenceRange {
        return FenceRange(
            earliest: min(earliest, other.earliest),
            latest: max(latest, other.latest)
        )
    }
}

/// Internal state structure for serializing fences to disk
internal struct FenceState: Codable {
    var fences: [FenceRange]
    let version: Int
    
    init(fences: [FenceRange] = []) {
        self.fences = fences
        self.version = 2
    }
}

/// Fence management utilities
public enum FenceManager {
    /// Check if a timestamp falls within any of the provided fences
    public static func isTimestampInFences(_ timestamp: Date, fences: [FenceRange]) -> Bool {
        return fences.contains { $0.contains(timestamp) }
    }
    
    /// Add a new fence to the existing fences, merging contiguous ones
    public static func addFence(newEarliest: Date, newLatest: Date, existingFences: [FenceRange]) -> [FenceRange] {
        var newFence = FenceRange(earliest: newEarliest, latest: newLatest)
        var result: [FenceRange] = []
        
        for existing in existingFences {
            if newFence.isContiguous(with: existing) {
                newFence = newFence.merged(with: existing)
            } else {
                result.append(existing)
            }
        }
        
        result.append(newFence)
        return mergeFences(result)
    }
    
    /// Merge multiple fences, combining any that are contiguous
    public static func mergeFences(_ fences: [FenceRange]) -> [FenceRange] {
        guard !fences.isEmpty else { return [] }
        
        let sorted = fences.sorted { $0.earliest < $1.earliest }
        var result: [FenceRange] = []
        var current = sorted[0]
        
        for i in 1..<sorted.count {
            let next = sorted[i]
            if current.isContiguous(with: next) {
                current = current.merged(with: next)
            } else {
                result.append(current)
                current = next
            }
        }
        
        result.append(current)
        return result
    }
    
    /// Create a JSON encoder configured for fence serialization (with fractional seconds)
    public static func createEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        // Use custom date encoding with fractional seconds to preserve precision
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let dateString = formatter.string(from: date)
            try container.encode(dateString)
        }
        return encoder
    }
    
    /// Create a JSON decoder configured for fence deserialization (with fractional seconds support)
    public static func createDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // Use custom date decoding that supports fractional seconds to preserve precision
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                return date
            }
            // Fallback to non-fractional format for backwards compatibility
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: dateString) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date string: \(dateString)")
            }
            return date
        }
        return decoder
    }
    
    /// Load fences from JSON data, handling version 2 format and old format migration
    /// - Parameter data: JSON data containing fence state
    /// - Parameter oldFormatType: Type to check for old format detection (e.g., `[String: Int64].self` or `[String: Int].self`)
    /// - Returns: Array of fence ranges, or empty array if migration detected or data invalid
    public static func loadFences<T: Decodable>(from data: Data, oldFormatType: T.Type) throws -> [FenceRange] {
        let decoder = createDecoder()
        
        // Try new format first (version 2)
        if let state = try? decoder.decode(FenceState.self, from: data) {
            return state.fences
        }
        
        // Try old format (ID-based) - if detected, return empty (migration/reset)
        if let _ = try? decoder.decode(oldFormatType, from: data) {
            return []
        }
        
        // If neither format works, return empty
        return []
    }
    
    /// Save fences to JSON data
    /// - Parameter fences: Array of fence ranges to save
    /// - Returns: Encoded JSON data
    public static func saveFences(_ fences: [FenceRange]) throws -> Data {
        let encoder = createEncoder()
        let state = FenceState(fences: fences)
        return try encoder.encode(state)
    }
}

