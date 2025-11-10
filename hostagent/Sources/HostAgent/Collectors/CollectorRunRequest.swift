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
        
        public init(since: Date? = nil, until: Date? = nil) {
            self.since = since
            self.until = until
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

    public struct FiltersConfig: Codable {
        public let combinationMode: String?
        public let defaultAction: String?
        public let inline: [AnyCodable]?
        public let files: [String]?
        public let environmentVariable: String?

        enum CodingKeys: String, CodingKey {
            case combinationMode = "combination_mode"
            case defaultAction = "default_action"
            case inline
            case files
            case environmentVariable = "environment_variable"
        }
        
        public init(combinationMode: String? = nil, defaultAction: String? = nil, inline: [AnyCodable]? = nil, files: [String]? = nil, environmentVariable: String? = nil) {
            self.combinationMode = combinationMode
            self.defaultAction = defaultAction
            self.inline = inline
            self.files = files
            self.environmentVariable = environmentVariable
        }
    }

    public struct RedactionOverride: Codable {
        // Dynamic structure to allow arbitrary PII type overrides
        public let raw: [String: Bool]

        public init(raw: [String: Bool] = [:]) {
            self.raw = raw
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var result: [String: Bool] = [:]
            for key in container.allKeys {
                if let value = try container.decodeIfPresent(Bool.self, forKey: key) {
                    result[key.stringValue] = value
                }
            }
            self.raw = result
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in raw {
                try container.encode(value, forKey: DynamicKey(stringValue: key)!)
            }
        }
    }

    public let mode: Mode?
    public let limit: Int?
    public let order: Order?
    /// concurrency is clamped to 1..12 when present
    public let concurrency: Int?
    public let dateRange: DateRange?
    public let timeWindow: String?  // ISO-8601 duration, e.g., "PT24H"
    public let batch: Bool?
    public let batchSize: Int?
    public let redactionOverride: RedactionOverride?
    public let filters: FiltersConfig?
    public let scope: AnyCodable?  // Collector-specific scope object
    public let force: Bool?  // Force re-ingestion by modifying idempotency keys

    enum CodingKeys: String, CodingKey {
        case mode
        case limit
        case order
        case concurrency
        case dateRange = "date_range"
        case timeWindow = "time_window"
        case batch
        case batchSize = "batch_size"
        case redactionOverride = "redaction_override"
        case filters
        case scope
        case force
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
    // Allow new fields
    let allowedKeys: Set<String> = ["mode", "limit", "order", "concurrency", "date_range", "time_window", "batch", "batch_size", "redaction_override", "filters", "scope", "force"]
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

        self.timeWindow = try keyed.decodeIfPresent(String.self, forKey: .timeWindow)

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

        self.redactionOverride = try keyed.decodeIfPresent(RedactionOverride.self, forKey: .redactionOverride)
        self.filters = try keyed.decodeIfPresent(FiltersConfig.self, forKey: .filters)
        self.scope = try keyed.decodeIfPresent(AnyCodable.self, forKey: .scope)
        self.force = try keyed.decodeIfPresent(Bool.self, forKey: .force)
    }
    
    // Public memberwise initializer for programmatic creation
    public init(
        mode: Mode? = nil,
        limit: Int? = nil,
        order: Order? = nil,
        concurrency: Int? = nil,
        dateRange: DateRange? = nil,
        timeWindow: String? = nil,
        batch: Bool? = nil,
        batchSize: Int? = nil,
        redactionOverride: RedactionOverride? = nil,
        filters: FiltersConfig? = nil,
        scope: AnyCodable? = nil,
        force: Bool? = nil
    ) {
        self.mode = mode
        self.limit = limit
        self.order = order
        self.concurrency = concurrency
        self.dateRange = dateRange
        self.timeWindow = timeWindow
        self.batch = batch
        self.batchSize = batchSize
        self.redactionOverride = redactionOverride
        self.filters = filters
        self.scope = scope
        self.force = force
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
        try container.encodeIfPresent(redactionOverride, forKey: .redactionOverride)
        try container.encodeIfPresent(filters, forKey: .filters)
        try container.encodeIfPresent(scope, forKey: .scope)
        try container.encodeIfPresent(force, forKey: .force)
    }

    // ISO8601 parsing helper used by nested types
    static func parseISO8601(_ s: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: s) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: s)
    }
    
    // MARK: - Scope Helpers
    
    /// Extract iMessage-specific scope fields
    public func getIMessageScope() -> IMessageScopeFields {
        guard let scopeData = scope else { return IMessageScopeFields() }
        let dict = scopeData.value as? [String: Any] ?? [:]
        return IMessageScopeFields(
            includeChats: dict["include_chats"] as? [String],
            excludeChats: dict["exclude_chats"] as? [String],
            includeAttachments: dict["include_attachments"] as? Bool ?? true,
            useOcrOnAttachments: dict["use_ocr_on_attachments"] as? Bool ?? false,
            extractEntities: dict["extract_entities"] as? Bool ?? false
        )
    }
    
    /// Extract IMAP-specific scope fields
    public func getImapScope() -> ImapScopeFields {
        guard let scopeData = scope else { return ImapScopeFields() }
        let dict = scopeData.value as? [String: Any] ?? [:]
        let connDict = dict["connection"] as? [String: Any] ?? [:]
        return ImapScopeFields(
            connectionHost: connDict["host"] as? String,
            connectionPort: connDict["port"] as? Int,
            connectionTls: connDict["tls"] as? Bool,
            connectionUsername: connDict["username"] as? String,
            connectionSecretRef: connDict["secret_ref"] as? String,
            folders: dict["folders"] as? [String]
        )
    }
    
    /// Extract LocalFS-specific scope fields
    public func getLocalfsScope() -> LocalfsScopeFields {
        guard let scopeData = scope else { return LocalfsScopeFields() }
        let dict = scopeData.value as? [String: Any] ?? [:]
        return LocalfsScopeFields(
            paths: dict["paths"] as? [String],
            includeGlobs: dict["include_globs"] as? [String],
            excludeGlobs: dict["exclude_globs"] as? [String]
        )
    }
    
    // MARK: - Scope Field Types
    
    public struct IMessageScopeFields {
        public let includeChats: [String]?
        public let excludeChats: [String]?
        public let includeAttachments: Bool
        public let useOcrOnAttachments: Bool
        public let extractEntities: Bool
        
        public init(includeChats: [String]? = nil, excludeChats: [String]? = nil,
                   includeAttachments: Bool = true, useOcrOnAttachments: Bool = false,
                   extractEntities: Bool = false) {
            self.includeChats = includeChats
            self.excludeChats = excludeChats
            self.includeAttachments = includeAttachments
            self.useOcrOnAttachments = useOcrOnAttachments
            self.extractEntities = extractEntities
        }
    }
    
    public struct ImapScopeFields {
        public let connectionHost: String?
        public let connectionPort: Int?
        public let connectionTls: Bool?
        public let connectionUsername: String?
        public let connectionSecretRef: String?
        public let folders: [String]?
        
        public init(connectionHost: String? = nil, connectionPort: Int? = nil,
                   connectionTls: Bool? = nil, connectionUsername: String? = nil,
                   connectionSecretRef: String? = nil, folders: [String]? = nil) {
            self.connectionHost = connectionHost
            self.connectionPort = connectionPort
            self.connectionTls = connectionTls
            self.connectionUsername = connectionUsername
            self.connectionSecretRef = connectionSecretRef
            self.folders = folders
        }
    }
    
    public struct LocalfsScopeFields {
        public let paths: [String]?
        public let includeGlobs: [String]?
        public let excludeGlobs: [String]?
        
        public init(paths: [String]? = nil, includeGlobs: [String]? = nil, excludeGlobs: [String]? = nil) {
            self.paths = paths
            self.includeGlobs = includeGlobs
            self.excludeGlobs = excludeGlobs
        }
    }
}

// Helper struct to encode/decode arbitrary JSON objects
public struct AnyCodable: Codable {
    public let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            var result: [String: Any] = [:]
            for (key, value) in dict {
                result[key] = value.value
            }
            self.value = result
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode AnyCodable")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        if let bool = value as? Bool {
            try container.encode(bool)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let string = value as? String {
            try container.encode(string)
        } else if let array = value as? [Any] {
            var aryContainer = encoder.unkeyedContainer()
            for item in array {
                try aryContainer.encode(AnyCodable(item))
            }
        } else if let dict = value as? [String: Any] {
            var dictContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in dict {
                let codingKey = DynamicCodingKey(stringValue: key)!
                try dictContainer.encode(AnyCodable(value), forKey: codingKey)
            }
        } else {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Cannot encode AnyCodable"))
        }
    }
    
    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) {
            self.stringValue = stringValue
        }
        var intValue: Int? { return nil }
        init?(intValue: Int) { return nil }
    }
}
