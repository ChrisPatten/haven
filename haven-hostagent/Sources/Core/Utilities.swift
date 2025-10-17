import CryptoKit
import Foundation
import Logging

public enum Hashing {
    public static func sha256Hex(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum DateUtils {
    public static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public struct AsyncThrottle: Sendable {
    private let minimumDelay: Duration
    private var lastRun: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    public init(minimumDelay: Duration) {
        self.minimumDelay = minimumDelay
    }

    public mutating func waitIfNeeded() async {
        if let lastRun {
            let elapsed = clock.now.duration(to: lastRun)
            if elapsed < minimumDelay {
                try? await Task.sleep(for: minimumDelay - elapsed)
            }
        }
        lastRun = clock.now
    }
}

public enum FileUtils {
    private static let logger = Logger(label: "HostAgent.FileUtils")

    public static func copyIfExists(_ url: URL, to destination: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            throw NSError(domain: "HostAgent.FileUtils", code: 1, userInfo: [NSLocalizedDescriptionKey: "Source not found \(url.path)"])
        }

        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: url, to: destination)
    }

    public static func createTemporaryDirectory(base: URL, prefix: String) throws -> URL {
        let dir = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func removeIfExists(_ url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            logger.warning("Failed to remove path", metadata: ["path": "\(url.path)", "error": "\(error)"])
        }
    }
}

@discardableResult
public func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    precondition(seconds >= 0, "Timeout must be non-negative")
    let durationNanoseconds = UInt64(max(seconds, 0) * 1_000_000_000)
    return try await withThrowingTaskGroup(of: T.self) { group -> T in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: durationNanoseconds)
            throw TimeoutError()
        }
        guard let result = try await group.next() else {
            throw TimeoutError()
        }
        group.cancelAll()
        return result
    }
}

public struct TimeoutError: Error, Sendable {
    public init() {}
}
