import Foundation
import OSLog

/// Structured JSON logger for Haven Host Agent
public struct HavenLogger {
    private let subsystem = "com.haven.hostagent"
    private let category: String
    private let osLog: OSLog
    // Global minimum level; messages below this will be suppressed.
    // Lower numeric == more verbose. Default is info.
    private static var minimumLevelPriority: Int = HavenLogger.priority(for: "info")
    // Logging output format: "json", "text", or "logfmt"
    private static var outputFormat: String = "json"
    
    public init(category: String) {
        self.category = category
        self.osLog = OSLog(subsystem: subsystem, category: category)
    }
    
    public func debug(_ message: String, metadata: [String: Any] = [:]) {
        log(level: "debug", message: message, metadata: metadata, osLogType: .debug)
    }
    
    public func info(_ message: String, metadata: [String: Any] = [:]) {
        log(level: "info", message: message, metadata: metadata, osLogType: .info)
    }
    
    public func warning(_ message: String, metadata: [String: Any] = [:]) {
        log(level: "warning", message: message, metadata: metadata, osLogType: .default)
    }
    
    public func error(_ message: String, metadata: [String: Any] = [:], error: Error? = nil) {
        var meta = metadata
        if let error = error {
            meta["error"] = error.localizedDescription
            meta["error_type"] = String(describing: type(of: error))
        }
        log(level: "error", message: message, metadata: meta, osLogType: .error)
    }
    
    private func log(level: String, message: String, metadata: [String: Any], osLogType: OSLogType) {
        // Respect global minimum level
        let msgPriority = HavenLogger.priority(for: level)
        if msgPriority < HavenLogger.minimumLevelPriority {
            return
        }
        var logData: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "lvl": level,
            "mod": category,
            "msg": message
        ]

        // Merge metadata
        for (key, value) in metadata {
            logData[key] = value
        }

        let fmt = HavenLogger.outputFormat.lowercased()
        switch fmt {
        case "text":
            // Human readable text: [lvl] category: message key=val ...
            var parts = ["[\(level)] \(category): \(message)"]
            if !metadata.isEmpty {
                let meta = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                parts.append(meta)
            }
            let out = parts.joined(separator: " ")
            os_log("%{public}@", log: osLog, type: osLogType, out)
            print(out)

        case "logfmt":
            // key=value format for log collectors
            var pairs: [String] = []
            pairs.append("ts=\(ISO8601DateFormatter().string(from: Date()))")
            pairs.append("lvl=\(level)")
            pairs.append("mod=\(category)")
            pairs.append("msg=\"\(message)\"")
            for (k, v) in metadata.sorted(by: { $0.key < $1.key }) {
                pairs.append("\(k)=\"\(v)\"")
            }
            let out = pairs.joined(separator: " ")
            os_log("%{public}@", log: osLog, type: osLogType, out)
            print(out)

        default:
            // Default: JSON structured output
            if let jsonData = try? JSONSerialization.data(withJSONObject: logData, options: [.sortedKeys]),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                os_log("%{public}@", log: osLog, type: osLogType, jsonString)
                print(jsonString)
            } else {
                // Fallback to text
                os_log("[%{public}@] %{public}@: %{public}@", log: osLog, type: osLogType, level, category, message)
                print("[\(level)] \(category): \(message)")
            }
        }
    }

    /// Set the global minimum level by name (e.g. "info", "warning").
    public static func setMinimumLevel(_ level: String) {
        HavenLogger.minimumLevelPriority = HavenLogger.priority(for: level)
    }

    /// Set the global output format (json, text, logfmt)
    public static func setOutputFormat(_ format: String) {
        HavenLogger.outputFormat = format.lowercased()
    }

    /// Map textual level to numeric priority. Higher means more severe.
    public static func priority(for level: String) -> Int {
        switch level.lowercased() {
        case "trace": return 0
        case "debug": return 10
        case "info": return 20
        case "notice": return 25
        case "warning", "warn": return 30
        case "error": return 40
        case "critical", "fatal": return 50
        default: return 20 // default to info
        }
    }
}

// MARK: - Request Context

public struct RequestContext {
    public let requestId: String
    public let startTime: Date
    public var metadata: [String: Any]
    
    public init(requestId: String? = nil) {
        self.requestId = requestId ?? UUID().uuidString
        self.startTime = Date()
        self.metadata = [:]
    }
    
    public func elapsed() -> TimeInterval {
        return Date().timeIntervalSince(startTime)
    }
    
    public func elapsedMs() -> Int {
        return Int(elapsed() * 1000)
    }
}

// MARK: - Metrics Collection

public actor MetricsCollector {
    private var counters: [String: Int] = [:]
    private var gauges: [String: Double] = [:]
    private var histograms: [String: [Double]] = [:]
    
    public static let shared = MetricsCollector()
    
    private init() {}
    
    public func incrementCounter(_ name: String, by value: Int = 1, labels: [String: String] = [:]) {
        let key = metricKey(name, labels: labels)
        counters[key, default: 0] += value
    }
    
    public func setGauge(_ name: String, value: Double, labels: [String: String] = [:]) {
        let key = metricKey(name, labels: labels)
        gauges[key] = value
    }
    
    public func recordHistogram(_ name: String, value: Double, labels: [String: String] = [:]) {
        let key = metricKey(name, labels: labels)
        histograms[key, default: []].append(value)
    }
    
    public func prometheusFormat() -> String {
        var lines: [String] = []
        
        // Counters
        for (key, value) in counters.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key) \(value)")
        }
        
        // Gauges
        for (key, value) in gauges.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key) \(value)")
        }
        
        // Histograms - emit count, sum, and percentiles
        for (key, values) in histograms.sorted(by: { $0.key < $1.key }) {
            let sorted = values.sorted()
            let count = sorted.count
            let sum = sorted.reduce(0, +)
            
            lines.append("\(key)_count \(count)")
            lines.append("\(key)_sum \(sum)")
            
            if count > 0 {
                let p50 = sorted[count / 2]
                let p95 = sorted[Int(Double(count) * 0.95)]
                let p99 = sorted[Int(Double(count) * 0.99)]
                
                lines.append("\(key)_p50 \(p50)")
                lines.append("\(key)_p95 \(p95)")
                lines.append("\(key)_p99 \(p99)")
            }
        }
        
        return lines.joined(separator: "\n") + "\n"
    }
    
    private func metricKey(_ name: String, labels: [String: String]) -> String {
        guard !labels.isEmpty else { return name }
        
        let labelPairs = labels.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\"\($0.value)\"" }
            .joined(separator: ",")
        
        return "\(name){\(labelPairs)}"
    }
}
