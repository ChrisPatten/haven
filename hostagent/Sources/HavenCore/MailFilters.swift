import Foundation

/// Errors that can occur while building or evaluating mail filters.
public enum MailFilterError: Error, LocalizedError, Equatable {
    case invalidExpression(String)
    case invalidPredicate(String)
    case invalidRegex(String)
    case invalidDateSpecifier(String)
    case fileNotFound(String)
    case unsupportedFormat(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidExpression(let reason):
            return "Invalid filter expression: \(reason)"
        case .invalidPredicate(let reason):
            return "Invalid filter predicate: \(reason)"
        case .invalidRegex(let pattern):
            return "Invalid regular expression: \(pattern)"
        case .invalidDateSpecifier(let value):
            return "Invalid date specifier: \(value)"
        case .fileNotFound(let path):
            return "Filter file not found: \(path)"
        case .unsupportedFormat(let format):
            return "Unsupported filter format: \(format)"
        }
    }
}

/// Represents an email attachment used during filter evaluation.
public struct EmailAttachmentInfo: Equatable {
    public var filename: String?
    public var mimeType: String?
    
    public init(filename: String? = nil, mimeType: String? = nil) {
        self.filename = filename
        self.mimeType = mimeType
    }
}

/// Lightweight context passed to the filter engine for evaluation.
public struct EmailFilterMessageContext {
    public var subject: String
    public var bodyPlaintext: String
    public var bodyHTML: String?
    public var from: [String]
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var folderPath: String?
    public var headers: [String: String]
    public var date: Date?
    public var isVIP: Bool
    public var hasListUnsubscribe: Bool
    public var attachments: [EmailAttachmentInfo]
    
    public init(subject: String = "",
                bodyPlaintext: String = "",
                bodyHTML: String? = nil,
                from: [String] = [],
                to: [String] = [],
                cc: [String] = [],
                bcc: [String] = [],
                folderPath: String? = nil,
                headers: [String: String] = [:],
                date: Date? = nil,
                isVIP: Bool = false,
                hasListUnsubscribe: Bool = false,
                attachments: [EmailAttachmentInfo] = []) {
        self.subject = subject
        self.bodyPlaintext = bodyPlaintext
        self.bodyHTML = bodyHTML
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.folderPath = folderPath
        self.headers = headers
        self.date = date
        self.isVIP = isVIP
        self.hasListUnsubscribe = hasListUnsubscribe
        self.attachments = attachments
    }
}

/// Identifies supported fields for regex/contains predicates.
public enum MailFilterFieldReference: Equatable {
    case subject
    case body
    case htmlBody
    case from
    case to
    case cc
    case bcc
    case participants
    case folder
    case header(String)
    
    public init?(raw: String) {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "subject":
            self = .subject
        case "body", "body_text", "body_plain", "text":
            self = .body
        case "body_html", "html", "html_body":
            self = .htmlBody
        case "from":
            self = .from
        case "to":
            self = .to
        case "cc":
            self = .cc
        case "bcc":
            self = .bcc
        case "participants":
            self = .participants
        case "folder", "mailbox":
            self = .folder
        default:
            if normalized.starts(with: "header:") {
                let name = String(normalized.dropFirst("header:".count))
                self = .header(name)
            } else {
                return nil
            }
        }
    }
    
    /// Render-friendly string identifier (used in error messages).
    public var description: String {
        switch self {
        case .subject: return "subject"
        case .body: return "body"
        case .htmlBody: return "body_html"
        case .from: return "from"
        case .to: return "to"
        case .cc: return "cc"
        case .bcc: return "bcc"
        case .participants: return "participants"
        case .folder: return "folder"
        case .header(let name): return "header:\(name)"
        }
    }
}

// MARK: - Filter Expression Model

/// Decodable representation of a logical filter expression tree.
public indirect enum MailFilterExpression: Equatable, Codable {
    case and([MailFilterExpression])
    case or([MailFilterExpression])
    case not(MailFilterExpression)
    case predicate(MailFilterPredicateDefinition)
    
    enum CodingKeys: CodingKey {
        case op
        case args
        case not
        case pred
        case predicate
    }
    
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            // Logical operators
            if let op = try container.decodeIfPresent(String.self, forKey: .op) {
                let args = try container.decode([MailFilterExpression].self, forKey: .args)
                switch op.lowercased() {
                case "and":
                    self = .and(args)
                case "or":
                    self = .or(args)
                default:
                    throw MailFilterError.invalidExpression("Unknown logical operator '\(op)'")
                }
                return
            }
            
            if let notExpr = try container.decodeIfPresent(MailFilterExpression.self, forKey: .not) {
                self = .not(notExpr)
                return
            }
            
            if container.contains(.predicate) || container.contains(.pred) {
                let predicate = try MailFilterPredicateDefinition(from: decoder)
                self = .predicate(predicate)
                return
            }
        }
        
        let singleValue = try decoder.singleValueContainer()
        
        if let expressionString = try? singleValue.decode(String.self) {
            self = try MailFilterDSLParser.parse(expressionString)
            return
        }
        
        if let predicate = try? singleValue.decode(MailFilterPredicateDefinition.self) {
            self = .predicate(predicate)
            return
        }
        
        throw MailFilterError.invalidExpression("Unable to decode expression")
    }
    
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .and(let expressions):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("and", forKey: .op)
            try container.encode(expressions, forKey: .args)
        case .or(let expressions):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("or", forKey: .op)
            try container.encode(expressions, forKey: .args)
        case .not(let expression):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(expression, forKey: .not)
        case .predicate(let predicate):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(predicate, forKey: .predicate)
        }
    }
    
    /// Convenience helper for callers building expressions from the mini-language.
    public static func fromDSL(_ expression: String) throws -> MailFilterExpression {
        try MailFilterDSLParser.parse(expression)
    }
}

/// Available predicate types prior to compilation.
public enum MailFilterPredicateDefinition: Equatable, Codable {
    case regex(field: MailFilterFieldReference, pattern: String, options: RegexOptionSet)
    case contains(field: MailFilterFieldReference, text: String, caseSensitive: Bool)
    case hasAttachment
    case attachmentMime(patterns: [String])
    case folderExact(String)
    case folderPrefix(String)
    case folderRegex(String)
    case vip(Bool)
    case listUnsubscribe(Bool)
    case date(DatePredicateDefinition)
    
    enum CodingKeys: String, CodingKey {
        case pred
        case predicate
        case args
        case field
        case pattern
        case options
        case text
        case caseSensitive = "case_sensitive"
        case value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let predicateName = try container.decodeIfPresent(String.self, forKey: .pred)
            ?? container.decodeIfPresent(String.self, forKey: .predicate)
            ?? { throw MailFilterError.invalidPredicate("Missing 'pred' name") }()
        
        let normalized = predicateName.lowercased()
        let args = try container.decodeIfPresent([DecodableValue].self, forKey: .args) ?? []
        
        func requireFieldArg(at index: Int) throws -> MailFilterFieldReference {
            guard args.count > index,
                  case .string(let fieldName) = args[index],
                  let field = MailFilterFieldReference(raw: fieldName) else {
                throw MailFilterError.invalidPredicate("Predicate '\(predicateName)' expects a field string argument at index \(index)")
            }
            return field
        }
        
        func requireStringArg(at index: Int) throws -> String {
            guard args.count > index else {
                throw MailFilterError.invalidPredicate("Predicate '\(predicateName)' expects string argument at index \(index)")
            }
            switch args[index] {
            case .string(let value):
                return value
            case .number(let value):
                return String(value)
            case .bool(let value):
                return value ? "true" : "false"
            default:
                throw MailFilterError.invalidPredicate("Predicate '\(predicateName)' expects string argument at index \(index)")
            }
        }
        
        func requireBoolArg(at index: Int, default defaultValue: Bool) throws -> Bool {
            guard args.count > index else {
                return defaultValue
            }
            switch args[index] {
            case .bool(let value):
                return value
            case .string(let value):
                return (value as NSString).boolValue
            case .number(let value):
                return value != 0
            default:
                return defaultValue
            }
        }
        
        switch normalized {
        case "regex":
            let field = try requireFieldArg(at: 0)
            let pattern = try requireStringArg(at: 1)
            // Optional options argument (e.g. ["caseInsensitive"])
            var regexOptions: RegexOptionSet = .default
            if args.count > 2 {
                switch args[2] {
                case .array(let values):
                    regexOptions = RegexOptionSet(values.compactMap { $0.stringValue })
                case .string(let value):
                    regexOptions = RegexOptionSet([value])
                default:
                    break
                }
            }
            self = .regex(field: field, pattern: pattern, options: regexOptions)
        case "contains":
            let field = try requireFieldArg(at: 0)
            let text = try requireStringArg(at: 1)
            let caseSensitive = try requireBoolArg(at: 2, default: false)
            self = .contains(field: field, text: text, caseSensitive: caseSensitive)
        case "has_attachment", "hasattachment":
            self = .hasAttachment
        case "attachment_mime", "attachmentmime":
            if args.isEmpty {
                throw MailFilterError.invalidPredicate("Predicate '\(predicateName)' requires at least one mime pattern")
            }
            let patterns: [String] = args
                .compactMap { $0.stringValue }
                .map { $0.trimmingRegexDelimiters() }
            self = .attachmentMime(patterns: patterns)
        case "folder_exact", "folderexact":
            self = .folderExact(try requireStringArg(at: 0))
        case "folder_prefix", "folderprefix":
            self = .folderPrefix(try requireStringArg(at: 0))
        case "folder_matches", "folder_regex":
            self = .folderRegex(try requireStringArg(at: 0))
        case "vip":
            let expected = try requireBoolArg(at: 0, default: true)
            self = .vip(expected)
        case "list_unsubscribe", "listunsubscribe":
            let expected = try requireBoolArg(at: 0, default: true)
            self = .listUnsubscribe(expected)
        case "date_range", "daterange":
            if args.isEmpty {
                throw MailFilterError.invalidPredicate("Predicate '\(predicateName)' expects at least one argument")
            }
            if args.count == 1 {
                guard let value = args[0].stringValue else {
                    throw MailFilterError.invalidPredicate("Predicate '\(predicateName)' expects string argument")
                }
                self = .date(.range(DateRangeSpecifier(start: .relativeOrAbsolute(value: value), end: nil)))
            } else if args.count >= 2 {
                guard let startString = args[0].stringValue,
                      let endString = args[1].stringValue else {
                    throw MailFilterError.invalidPredicate("Predicate '\(predicateName)' expects string arguments")
                }
                self = .date(.range(DateRangeSpecifier(
                    start: .relativeOrAbsolute(value: startString),
                    end: .relativeOrAbsolute(value: endString)
                )))
            } else {
                throw MailFilterError.invalidPredicate("Predicate '\(predicateName)' received unexpected arguments")
            }
        case "date_between", "datebetween":
            let start = try requireStringArg(at: 0)
            let end = try requireStringArg(at: 1)
            self = .date(.between(
                .relativeOrAbsolute(value: start),
                .relativeOrAbsolute(value: end)
            ))
        case "date_after", "dateafter":
            self = .date(.comparison(.after, .relativeOrAbsolute(value: try requireStringArg(at: 0))))
        case "date_before", "datebefore":
            self = .date(.comparison(.before, .relativeOrAbsolute(value: try requireStringArg(at: 0))))
        case "date_on_or_after", "dateonorafter":
            self = .date(.comparison(.onOrAfter, .relativeOrAbsolute(value: try requireStringArg(at: 0))))
        case "date_on_or_before", "dateonorbefore":
            self = .date(.comparison(.onOrBefore, .relativeOrAbsolute(value: try requireStringArg(at: 0))))
        default:
            throw MailFilterError.invalidPredicate("Unknown predicate '\(predicateName)'")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .regex(let field, let pattern, let options):
            try container.encode("regex", forKey: .pred)
            var args = container.nestedUnkeyedContainer(forKey: .args)
            try args.encode(field.description)
            try args.encode(pattern)
            if options.values.isEmpty == false {
                try args.encode(Array(options.values))
            }
        case .contains(let field, let text, let caseSensitive):
            try container.encode("contains", forKey: .pred)
            var args = container.nestedUnkeyedContainer(forKey: .args)
            try args.encode(field.description)
            try args.encode(text)
            try args.encode(caseSensitive)
        case .hasAttachment:
            try container.encode("has_attachment", forKey: .pred)
        case .attachmentMime(let patterns):
            try container.encode("attachment_mime", forKey: .pred)
            var args = container.nestedUnkeyedContainer(forKey: .args)
            for pattern in patterns {
                try args.encode(pattern)
            }
        case .folderExact(let folder):
            try container.encode("folder_exact", forKey: .pred)
            var args = container.nestedUnkeyedContainer(forKey: .args)
            try args.encode(folder)
        case .folderPrefix(let prefix):
            try container.encode("folder_prefix", forKey: .pred)
            var args = container.nestedUnkeyedContainer(forKey: .args)
            try args.encode(prefix)
        case .folderRegex(let pattern):
            try container.encode("folder_regex", forKey: .pred)
            var args = container.nestedUnkeyedContainer(forKey: .args)
            try args.encode(pattern)
        case .vip(let expected):
            try container.encode("vip", forKey: .pred)
            var args = container.nestedUnkeyedContainer(forKey: .args)
            try args.encode(expected)
        case .listUnsubscribe(let expected):
            try container.encode("list_unsubscribe", forKey: .pred)
            var args = container.nestedUnkeyedContainer(forKey: .args)
            try args.encode(expected)
        case .date(let definition):
            switch definition {
            case .range(let specifier):
                try container.encode("date_range", forKey: .pred)
                var args = container.nestedUnkeyedContainer(forKey: .args)
                try args.encode(specifier.start.rawValue)
                if let end = specifier.end?.rawValue {
                    try args.encode(end)
                }
            case .between(let start, let end):
                try container.encode("date_between", forKey: .pred)
                var args = container.nestedUnkeyedContainer(forKey: .args)
                try args.encode(start.rawValue)
                try args.encode(end.rawValue)
            case .comparison(let comparator, let bound):
                let predicateName: String
                switch comparator {
                case .before: predicateName = "date_before"
                case .after: predicateName = "date_after"
                case .onOrBefore: predicateName = "date_on_or_before"
                case .onOrAfter: predicateName = "date_on_or_after"
                }
                try container.encode(predicateName, forKey: .pred)
                var args = container.nestedUnkeyedContainer(forKey: .args)
                try args.encode(bound.rawValue)
            }
        }
    }
}

/// Helper value type used while decoding predicate arguments.
private enum DecodableValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([DecodableValue])
    case object([String: DecodableValue])
    case null
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let array = try? container.decode([DecodableValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: DecodableValue].self) {
            self = .object(object)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.typeMismatch(DecodableValue.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported value"))
        }
    }
    
    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }
}

/// Represents an ISO8601 or relative date specifier used in predicates.
public enum DateBoundRepresentation: Equatable {
    case absolute(String)
    case relative(String)
    
    public static func relativeOrAbsolute(value: String) -> DateBoundRepresentation {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-")
            || value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+") {
            return .relative(value)
        }
        return .absolute(value)
    }
    
    public var rawValue: String {
        switch self {
        case .absolute(let value): return value
        case .relative(let value): return value
        }
    }
}

/// Variants of date-based predicates.
public enum DatePredicateDefinition: Equatable {
    case range(DateRangeSpecifier)
    case between(DateBoundRepresentation, DateBoundRepresentation)
    case comparison(DateComparisonOperator, DateBoundRepresentation)
}

public enum DateComparisonOperator: String, Codable, Equatable {
    case before
    case after
    case onOrBefore = "on_or_before"
    case onOrAfter = "on_or_after"
}

public struct DateRangeSpecifier: Equatable {
    public var start: DateBoundRepresentation
    public var end: DateBoundRepresentation?
    
    public init(start: DateBoundRepresentation, end: DateBoundRepresentation?) {
        self.start = start
        self.end = end
    }
}

/// Expressible set of Regex options understood by the parser.
public struct RegexOptionSet: Equatable {
    public static let `default` = RegexOptionSet([])
    
    public var values: Set<String>
    
    public init(_ values: [String]) {
        self.values = Set(values.map { $0.lowercased() })
    }
    
    public func toNSOptions(pattern: String) -> NSRegularExpression.Options {
        var options: NSRegularExpression.Options = []
        if values.contains("case_insensitive") || pattern.contains("(?i)") {
            options.insert(.caseInsensitive)
        }
        if values.contains("allow_comments_and_whitespace") {
            options.insert(.allowCommentsAndWhitespace)
        }
        if values.contains("dot_matches_newlines") {
            options.insert(.dotMatchesLineSeparators)
        }
        return options
    }
}

// MARK: - Compilation

public final class MailFilterEvaluator {
    public struct BuildOptions {
        public var cliExpressions: [String]
        public var environment: [String: String]
        public var fileManager: FileManager
        public var nowProvider: () -> Date
        
        public init(cliExpressions: [String] = [],
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    fileManager: FileManager = .default,
                    nowProvider: @escaping () -> Date = { Date() }) {
            self.cliExpressions = cliExpressions
            self.environment = environment
            self.fileManager = fileManager
            self.nowProvider = nowProvider
        }
    }
    
    public let expressions: [CompiledMailFilterExpression]
    public let combinationMode: MailFilterCombinationMode
    public let defaultAction: MailFilterDefaultAction
    public let prefilter: MailPrefilterConfig
    
    private let nowProvider: () -> Date
    
    private init(expressions: [CompiledMailFilterExpression],
                 combinationMode: MailFilterCombinationMode,
                 defaultAction: MailFilterDefaultAction,
                 prefilter: MailPrefilterConfig,
                 nowProvider: @escaping () -> Date) {
        self.expressions = expressions
        self.combinationMode = combinationMode
        self.defaultAction = defaultAction
        self.prefilter = prefilter
        self.nowProvider = nowProvider
    }
    
    public static func build(
        config: MailFiltersConfig,
        options: BuildOptions = BuildOptions()
    ) throws -> MailFilterEvaluator {
        var expressions = config.inline
        var combinationMode = config.combinationMode
        var defaultAction = config.defaultAction
        var prefilter = config.prefilter
        
        let loader = MailFilterSourceLoader(fileManager: options.fileManager)
        
        // Load from files
        for rawPath in config.files {
            let expanded = loader.expandTilde(in: rawPath)
            guard loader.fileExists(at: expanded) else {
                continue
            }
            let document = try loader.loadDocument(at: expanded)
            expressions.append(contentsOf: document.expressions)
            if let docMode = document.combinationMode {
                combinationMode = docMode
            }
            if let docAction = document.defaultAction {
                defaultAction = docAction
            }
            if let docPrefilter = document.prefilter {
                prefilter = prefilter.merging(docPrefilter)
            }
        }
        
        // Environment variable
        if let envName = config.environmentVariable,
           let envValue = options.environment[envName],
           envValue.isEmpty == false {
            let document = try loader.loadDocument(from: envValue, presumedName: "env:\(envName)")
            expressions.append(contentsOf: document.expressions)
            if let docMode = document.combinationMode {
                combinationMode = docMode
            }
            if let docAction = document.defaultAction {
                defaultAction = docAction
            }
            if let docPrefilter = document.prefilter {
                prefilter = prefilter.merging(docPrefilter)
            }
        }
        
        // CLI expressions
        for cliExpression in options.cliExpressions where cliExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            let parsed = try MailFilterDSLParser.parse(cliExpression)
            expressions.append(parsed)
        }
        
        // Derive prefilter hints from expressions when safe
        let derivedHints = MailPrefilterConfig.derived(from: expressions, mode: combinationMode)
        prefilter = prefilter.merging(derivedHints)
        
        // Compile expressions
        let compiled = try expressions.map { try CompiledMailFilterExpression(expression: $0) }
        let evaluator = MailFilterEvaluator(
            expressions: compiled,
            combinationMode: combinationMode,
            defaultAction: defaultAction,
            prefilter: prefilter,
            nowProvider: options.nowProvider
        )
        return evaluator
    }
    
    public func evaluate(_ message: EmailFilterMessageContext) -> Bool {
        if let folder = message.folderPath?.lowercased() {
            if prefilter.isExcluded(folder: folder) {
                return false
            }
            if prefilter.shouldRestrictToFolderList,
               prefilter.isIncludedFolderListEmpty == false,
               prefilter.isIncluded(folder: folder) == false {
                return false
            }
        } else if prefilter.shouldRestrictToFolderList && prefilter.isIncludedFolderListEmpty == false {
            // No folder information, but include list exists -> reject quickly
            return false
        }
        
        if prefilter.vipOnly && message.isVIP == false {
            return false
        }
        
        if prefilter.requireListUnsubscribe && message.hasListUnsubscribe == false {
            return false
        }
        
        if expressions.isEmpty {
            return defaultAction == .include
        }
        
        let now = nowProvider()
        let results = expressions.map { $0.evaluate(message: message, now: now) }
        
        switch combinationMode {
        case .any:
            if results.contains(true) {
                return true
            }
            return false
        case .all:
            return results.allSatisfy { $0 }
        }
    }
}

// MARK: - Prefilter Helpers

extension MailPrefilterConfig {
    var shouldRestrictToFolderList: Bool {
        return !includeFolders.isEmpty
    }
    
    var isIncludedFolderListEmpty: Bool {
        return includeFolders.isEmpty
    }
    
    func isIncluded(folder: String) -> Bool {
        let normalized = folder.lowercased()
        return includeFolders.contains { normalized.hasPrefix($0.lowercased()) }
    }
    
    func isExcluded(folder: String) -> Bool {
        let normalized = folder.lowercased()
        return excludeFolders.contains { normalized.hasPrefix($0.lowercased()) }
    }
    
    func merging(_ other: MailPrefilterConfig) -> MailPrefilterConfig {
        var merged = self
        merged.includeFolders.append(contentsOf: other.includeFolders)
        merged.excludeFolders.append(contentsOf: other.excludeFolders)
        merged.includeFolders = Array(Set(merged.includeFolders.map { $0.lowercased() }))
        merged.excludeFolders = Array(Set(merged.excludeFolders.map { $0.lowercased() }))
        merged.vipOnly = merged.vipOnly || other.vipOnly
        merged.requireListUnsubscribe = merged.requireListUnsubscribe || other.requireListUnsubscribe
        return merged
    }
    
    static func derived(from expressions: [MailFilterExpression],
                        mode: MailFilterCombinationMode) -> MailPrefilterConfig {
        var result = MailPrefilterConfig()
        switch mode {
        case .all:
            for expression in expressions {
                guard let hints = expression.collectFolderPredicates(), hints.isRestrictive else {
                    continue
                }
                result.includeFolders.append(contentsOf: hints.allPrefixes())
            }
        case .any:
            var derivedCollections: [FolderPredicateCollection] = []
            for expression in expressions {
                guard let hints = expression.collectFolderPredicates(),
                      hints.isRestrictive else {
                    // If any expression has no folder restriction, we cannot derive a safe include list
                    derivedCollections.removeAll()
                    break
                }
                derivedCollections.append(hints)
            }
            if derivedCollections.isEmpty == false {
                for hints in derivedCollections {
                    result.includeFolders.append(contentsOf: hints.allPrefixes())
                }
            }
        }
        if result.includeFolders.isEmpty == false {
            result.includeFolders = Array(Set(result.includeFolders.map { $0.lowercased() }))
        }
        return result
    }
}

// MARK: - Compiled Expression

public indirect enum CompiledMailFilterExpression {
    case and([CompiledMailFilterExpression])
    case or([CompiledMailFilterExpression])
    case not(CompiledMailFilterExpression)
    case predicate(CompiledMailFilterPredicate)
    
    init(expression: MailFilterExpression) throws {
        switch expression {
        case .and(let subexpressions):
            self = .and(try subexpressions.map { try CompiledMailFilterExpression(expression: $0) })
        case .or(let subexpressions):
            self = .or(try subexpressions.map { try CompiledMailFilterExpression(expression: $0) })
        case .not(let subexpression):
            self = .not(try CompiledMailFilterExpression(expression: subexpression))
        case .predicate(let predicate):
            self = .predicate(try CompiledMailFilterPredicate(predicate: predicate))
        }
    }
    
    func evaluate(message: EmailFilterMessageContext, now: Date) -> Bool {
        switch self {
        case .and(let expressions):
            for expression in expressions {
                if expression.evaluate(message: message, now: now) == false {
                    return false
                }
            }
            return true
        case .or(let expressions):
            for expression in expressions {
                if expression.evaluate(message: message, now: now) {
                    return true
                }
            }
            return false
        case .not(let expression):
            return expression.evaluate(message: message, now: now) == false
        case .predicate(let predicate):
            return predicate.evaluate(message: message, now: now)
        }
    }
}

public enum CompiledMailFilterPredicate {
    case regex(field: MailFilterFieldReference, regex: NSRegularExpression)
    case contains(field: MailFilterFieldReference, text: String, caseSensitive: Bool)
    case hasAttachment
    case attachmentMime([NSRegularExpression])
    case folderExact(String)
    case folderPrefix(String)
    case folderRegex(NSRegularExpression)
    case vip(Bool)
    case listUnsubscribe(Bool)
    case date(DatePredicate)
    
    init(predicate: MailFilterPredicateDefinition) throws {
        switch predicate {
        case .regex(let field, let pattern, let options):
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: options.toNSOptions(pattern: pattern))
                self = .regex(field: field, regex: regex)
            } catch {
                throw MailFilterError.invalidRegex(pattern)
            }
        case .contains(let field, let text, let caseSensitive):
            self = .contains(field: field, text: text, caseSensitive: caseSensitive)
        case .hasAttachment:
            self = .hasAttachment
        case .attachmentMime(let patterns):
            let regexes: [NSRegularExpression] = try patterns.map { pattern in
                do {
                    return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                } catch {
                    throw MailFilterError.invalidRegex(pattern)
                }
            }
            self = .attachmentMime(regexes)
        case .folderExact(let folder):
            self = .folderExact(folder.lowercased())
        case .folderPrefix(let prefix):
            self = .folderPrefix(prefix.lowercased())
        case .folderRegex(let pattern):
            do {
                self = .folderRegex(try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
            } catch {
                throw MailFilterError.invalidRegex(pattern)
            }
        case .vip(let expected):
            self = .vip(expected)
        case .listUnsubscribe(let expected):
            self = .listUnsubscribe(expected)
        case .date(let definition):
            self = .date(try DatePredicate(definition: definition))
        }
    }
    
    func evaluate(message: EmailFilterMessageContext, now: Date) -> Bool {
        switch self {
        case .regex(let field, let regex):
            let values = field.values(for: message)
            return values.contains { regex.firstMatch(in: $0, range: NSRange(location: 0, length: $0.utf16.count)) != nil }
        case .contains(let field, let text, let caseSensitive):
            let values = field.values(for: message)
            if caseSensitive {
                return values.contains { $0.contains(text) }
            } else {
                let lowered = text.lowercased()
                return values.contains { $0.lowercased().contains(lowered) }
            }
        case .hasAttachment:
            return message.attachments.isEmpty == false
        case .attachmentMime(let regexes):
            return message.attachments.contains { attachment in
                guard let mime = attachment.mimeType else { return false }
                return regexes.contains { regex in
                    let range = NSRange(location: 0, length: mime.utf16.count)
                    return regex.firstMatch(in: mime, range: range) != nil
                }
            }
        case .folderExact(let folder):
            guard let messageFolder = message.folderPath?.lowercased() else { return false }
            return messageFolder == folder
        case .folderPrefix(let prefix):
            guard let messageFolder = message.folderPath?.lowercased() else { return false }
            return messageFolder.hasPrefix(prefix)
        case .folderRegex(let regex):
            guard let folder = message.folderPath else { return false }
            let range = NSRange(location: 0, length: folder.utf16.count)
            return regex.firstMatch(in: folder, range: range) != nil
        case .vip(let expected):
            return message.isVIP == expected
        case .listUnsubscribe(let expected):
            return message.hasListUnsubscribe == expected
        case .date(let predicate):
            guard let date = message.date else { return false }
            return predicate.evaluate(date: date, now: now)
        }
    }
}

// MARK: - Date Predicate Compilation/Evaluation

public struct DatePredicate {
    public enum Bound {
        case absolute(Date)
        case relative(RelativeDuration)
        
        func resolve(now: Date) -> Date? {
            switch self {
            case .absolute(let date):
                return date
            case .relative(let duration):
                return duration.resolve(relativeTo: now)
            }
        }
    }
    
    public enum Variant {
        case range(Bound, Bound?)
        case between(Bound, Bound)
        case comparison(DateComparisonOperator, Bound)
    }
    
    public let variant: Variant
    
    init(definition: DatePredicateDefinition) throws {
        let converter = DateBoundConverter()
        switch definition {
        case .range(let specifier):
            let start = try converter.convert(bound: specifier.start)
            let end = try specifier.end.map { try converter.convert(bound: $0) }
            self.variant = .range(start, end)
        case .between(let startRaw, let endRaw):
            self.variant = .between(
                try converter.convert(bound: startRaw),
                try converter.convert(bound: endRaw)
            )
        case .comparison(let op, let boundRaw):
            self.variant = .comparison(op, try converter.convert(bound: boundRaw))
        }
    }
    
    public func evaluate(date: Date, now: Date) -> Bool {
        switch variant {
        case .range(let start, let maybeEnd):
            guard let lower = start.resolve(now: now) else { return false }
            if let end = maybeEnd {
                guard let upper = end.resolve(now: now) else { return false }
                return date >= lower && date <= upper
            }
            return date >= lower
        case .between(let start, let end):
            guard let lower = start.resolve(now: now),
                  let upper = end.resolve(now: now) else { return false }
            return date >= lower && date <= upper
        case .comparison(let op, let bound):
            guard let pivot = bound.resolve(now: now) else { return false }
            switch op {
            case .before:
                return date < pivot
            case .after:
                return date > pivot
            case .onOrBefore:
                return date <= pivot
            case .onOrAfter:
                return date >= pivot
            }
        }
    }
}

public struct RelativeDuration: Equatable {
    public var value: Double
    public var unit: TimeUnit
    
    public enum TimeUnit {
        case minutes
        case hours
        case days
        case weeks
    }
    
    public func resolve(relativeTo date: Date) -> Date? {
        let seconds: Double
        switch unit {
        case .minutes:
            seconds = value * 60
        case .hours:
            seconds = value * 3600
        case .days:
            seconds = value * 86_400
        case .weeks:
            seconds = value * 604_800
        }
        return date.addingTimeInterval(seconds)
    }
}

private struct DateBoundConverter {
    private let isoFormatter: ISO8601DateFormatter
    private let dateFormatter: DateFormatter
    
    init() {
        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .iso8601)
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
    }
    
    func convert(bound: DateBoundRepresentation) throws -> DatePredicate.Bound {
        switch bound {
        case .absolute(let raw):
            if let date = isoDate(from: raw) ?? dateFormatter.date(from: raw.trimmed()) {
                return .absolute(date)
            }
            throw MailFilterError.invalidDateSpecifier(raw)
        case .relative(let raw):
            guard let duration = RelativeDurationParser.parse(raw) else {
                throw MailFilterError.invalidDateSpecifier(raw)
            }
            return .relative(duration)
        }
    }
    
    private func isoDate(from raw: String) -> Date? {
        if let date = isoFormatter.date(from: raw) {
            return date
        }
        let shortFormatter = ISO8601DateFormatter()
        shortFormatter.formatOptions = [.withInternetDateTime]
        return shortFormatter.date(from: raw)
    }
}

private struct RelativeDurationParser {
    static func parse(_ raw: String) -> RelativeDuration? {
        let trimmed = raw.trimmed()
        guard trimmed.isEmpty == false else { return nil }
        
        var sign: Double = 1.0
        var cursor = trimmed
        if cursor.hasPrefix("+") {
            cursor = String(cursor.dropFirst())
        } else if cursor.hasPrefix("-") {
            sign = -1.0
            cursor = String(cursor.dropFirst())
        }
        
        // Split numeric prefix
        var numericPart = ""
        var remainder = ""
        for character in cursor {
            if character.isNumber || character == "." {
                numericPart.append(character)
            } else {
                remainder.append(character)
            }
        }
        
        guard let value = Double(numericPart) else {
            return nil
        }
        
        let normalizedUnit = remainder.trimmed().lowercased()
        let unit: RelativeDuration.TimeUnit
        switch normalizedUnit {
        case "", "d", "day", "days":
            unit = .days
        case "h", "hr", "hrs", "hour", "hours":
            unit = .hours
        case "m", "min", "mins", "minute", "minutes":
            unit = .minutes
        case "w", "week", "weeks":
            unit = .weeks
        default:
            return nil
        }
        
        return RelativeDuration(value: value * sign, unit: unit)
    }
}

// MARK: - DSL Parser

private enum DSLToken: Equatable {
    case identifier(String)
    case string(String)
    case number(Double)
    case boolean(Bool)
    case comma
    case lParen
    case rParen
    case not
    case and
    case or
}

private struct MailFilterDSLParser {
    static func parse(_ input: String) throws -> MailFilterExpression {
        let normalized = DateExpressionNormalizer.normalize(input)
        let tokenizer = DSLTokenizer(input: normalized)
        let tokens = try tokenizer.tokenize()
        var stream = DSLTokenStream(tokens: tokens)
        let expression = try parseOr(&stream)
        if stream.hasMoreTokens {
            throw MailFilterError.invalidExpression("Unexpected trailing tokens")
        }
        return expression
    }
    
    private static func parseOr(_ stream: inout DSLTokenStream) throws -> MailFilterExpression {
        var expressions: [MailFilterExpression] = []
        var current = try parseAnd(&stream)
        expressions.append(current)
        
        while stream.peek() == .or {
            stream.consume() // or
            current = try parseAnd(&stream)
            expressions.append(current)
        }
        
        if expressions.count == 1 {
            return expressions[0]
        }
        return .or(expressions)
    }
    
    private static func parseAnd(_ stream: inout DSLTokenStream) throws -> MailFilterExpression {
        var expressions: [MailFilterExpression] = []
        var current = try parseNot(&stream)
        expressions.append(current)
        
        while stream.peek() == .and {
            stream.consume()
            current = try parseNot(&stream)
            expressions.append(current)
        }
        
        if expressions.count == 1 {
            return expressions[0]
        }
        return .and(expressions)
    }
    
    private static func parseNot(_ stream: inout DSLTokenStream) throws -> MailFilterExpression {
        var notCount = 0
        while stream.peek() == .not {
            stream.consume()
            notCount += 1
        }
        var expression = try parsePrimary(&stream)
        if notCount % 2 == 1 {
            expression = .not(expression)
        }
        return expression
    }
    
    private static func parsePrimary(_ stream: inout DSLTokenStream) throws -> MailFilterExpression {
        guard let token = stream.consume() else {
            throw MailFilterError.invalidExpression("Unexpected end of expression")
        }
        
        switch token {
        case .identifier(let name):
            if stream.consumeIf(.lParen) {
                let args = try parseArguments(&stream)
                try stream.expect(.rParen)
                let predicate = try MailFilterPredicateBuilder.build(name: name, arguments: args)
                return .predicate(predicate)
            } else {
                throw MailFilterError.invalidExpression("Unexpected identifier '\(name)'")
            }
        case .lParen:
            let expression = try parseOr(&stream)
            try stream.expect(.rParen)
            return expression
        default:
            throw MailFilterError.invalidExpression("Unexpected token \(token)")
        }
    }
    
    private static func parseArguments(_ stream: inout DSLTokenStream) throws -> [DSLValue] {
        var values: [DSLValue] = []
        if stream.peek() == .rParen {
            return values
        }
        
        while true {
            let value = try parseArgumentValue(&stream)
            values.append(value)
            if stream.peek() == .comma {
                stream.consume()
                continue
            } else {
                break
            }
        }
        return values
    }
    
    private static func parseArgumentValue(_ stream: inout DSLTokenStream) throws -> DSLValue {
        guard let token = stream.consume() else {
            throw MailFilterError.invalidExpression("Expected argument value")
        }
        
        switch token {
        case .identifier(let value):
            return .identifier(value)
        case .string(let value):
            return .string(value)
        case .number(let value):
            return .number(value)
        case .boolean(let value):
            return .boolean(value)
        default:
            throw MailFilterError.invalidExpression("Unexpected token in argument list")
        }
    }
}

private enum DSLValue {
    case identifier(String)
    case string(String)
    case number(Double)
    case boolean(Bool)
    
    var stringRepresentation: String? {
        switch self {
        case .identifier(let value): return value
        case .string(let value): return value
        case .number(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        }
    }
}

private struct DSLTokenizer {
    let input: String
    
    func tokenize() throws -> [DSLToken] {
        var tokens: [DSLToken] = []
        var index = input.startIndex
        
        func advance() {
            index = input.index(after: index)
        }
        
        func currentChar() -> Character? {
            guard index < input.endIndex else { return nil }
            return input[index]
        }
        
        while let char = currentChar() {
            if char.isWhitespace {
                advance()
                continue
            }
            
            if char == "(" {
                tokens.append(.lParen)
                advance()
                continue
            } else if char == ")" {
                tokens.append(.rParen)
                advance()
                continue
            } else if char == "," {
                tokens.append(.comma)
                advance()
                continue
            } else if char == "'" || char == "\"" {
                let value = try readQuotedString(startQuote: char, index: &index)
                tokens.append(.string(value))
                continue
            } else if char == "/" {
                let value = try readRegexLiteral(index: &index)
                tokens.append(.string(value))
                continue
            } else if char.isNumber || char == "-" || char == "+" {
                let value = readNumber(startIndex: &index)
                tokens.append(.number(value))
                continue
            } else {
                let identifier = readIdentifier(startIndex: &index)
                switch identifier.lowercased() {
                case "and":
                    tokens.append(.and)
                case "or":
                    tokens.append(.or)
                case "not":
                    tokens.append(.not)
                case "true":
                    tokens.append(.boolean(true))
                case "false":
                    tokens.append(.boolean(false))
                default:
                    tokens.append(.identifier(identifier))
                }
                continue
            }
        }
        
        return tokens
    }
    
    private func readQuotedString(startQuote: Character, index: inout String.Index) throws -> String {
        let quote = startQuote
        index = input.index(after: index) // skip quote
        var result = ""
        while index < input.endIndex {
            let char = input[index]
            if char == "\\" {
                let nextIndex = input.index(after: index)
                guard nextIndex < input.endIndex else {
                    throw MailFilterError.invalidExpression("Unterminated escape sequence")
                }
                let escapedChar = input[nextIndex]
                result.append(escapedChar)
                index = input.index(after: nextIndex)
                continue
            } else if char == quote {
                index = input.index(after: index)
                return result
            } else {
                result.append(char)
                index = input.index(after: index)
            }
        }
        throw MailFilterError.invalidExpression("Unterminated string literal")
    }
    
    private func readRegexLiteral(index: inout String.Index) throws -> String {
        let start = index
        index = input.index(after: index) // skip leading slash
        var result = ""
        while index < input.endIndex {
            let char = input[index]
            if char == "\\" {
                let next = input.index(after: index)
                guard next < input.endIndex else {
                    throw MailFilterError.invalidExpression("Unterminated regex literal")
                }
                result.append(char)
                result.append(input[next])
                index = input.index(after: next)
            } else if char == "/" {
                index = input.index(after: index)
                return result
            } else {
                result.append(char)
                index = input.index(after: index)
            }
        }
        let literal = input[start...]
        throw MailFilterError.invalidExpression("Unterminated regex literal: \(literal)")
    }
    
    private func readNumber(startIndex: inout String.Index) -> Double {
        var index = startIndex
        var buffer = ""
        
        while index < input.endIndex {
            let char = input[index]
            if char.isNumber || char == "." || char == "+" || char == "-" {
                buffer.append(char)
                index = input.index(after: index)
            } else {
                break
            }
        }
        startIndex = index
        return Double(buffer) ?? 0
    }
    
    private func readIdentifier(startIndex: inout String.Index) -> String {
        var index = startIndex
        var buffer = ""
        while index < input.endIndex {
            let char = input[index]
            if char.isLetter || char.isNumber || char == "_" || char == ":" || char == "." || char == "-" {
                buffer.append(char)
                index = input.index(after: index)
            } else {
                break
            }
        }
        startIndex = index
        return buffer
    }
}

private struct DSLTokenStream {
    private(set) var tokens: [DSLToken]
    private var index: Int = 0
    
    init(tokens: [DSLToken]) {
        self.tokens = tokens
    }
    
    var hasMoreTokens: Bool {
        index < tokens.count
    }
    
    mutating func consume() -> DSLToken? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]
        index += 1
        return token
    }
    
    mutating func consumeIf(_ candidate: DSLToken) -> Bool {
        if peek() == candidate {
            index += 1
            return true
        }
        return false
    }
    
    func peek() -> DSLToken? {
        guard index < tokens.count else { return nil }
        return tokens[index]
    }
    
    mutating func expect(_ expected: DSLToken) throws {
        guard let token = consume(), token == expected else {
            throw MailFilterError.invalidExpression("Expected token \(expected) but found \(String(describing: peek()))")
        }
    }
}

private struct MailFilterPredicateBuilder {
    static func build(name: String, arguments: [DSLValue]) throws -> MailFilterPredicateDefinition {
        let normalized = name.lowercased()
        switch normalized {
        case "regex":
            guard let fieldValue = arguments.first?.stringRepresentation,
                  let field = MailFilterFieldReference(raw: fieldValue),
                  let pattern = arguments.dropFirst().first?.stringRepresentation else {
                throw MailFilterError.invalidPredicate("regex(field, pattern)")
            }
            var options = RegexOptionSet.default
            if arguments.count > 2 {
                let optionArgs = arguments.dropFirst(2).compactMap { $0.stringRepresentation }
                options = RegexOptionSet(optionArgs)
            }
            return .regex(field: field, pattern: pattern, options: options)
        case "contains":
            guard let fieldValue = arguments.first?.stringRepresentation,
                  let field = MailFilterFieldReference(raw: fieldValue),
                  let text = arguments.dropFirst().first?.stringRepresentation else {
                throw MailFilterError.invalidPredicate("contains(field, text)")
            }
            var caseSensitive = false
            if arguments.count > 2, let boolValue = arguments[2].stringRepresentation {
                caseSensitive = (boolValue as NSString).boolValue
            }
            return .contains(field: field, text: text, caseSensitive: caseSensitive)
        case "has_attachment", "hasattachment":
            return .hasAttachment
        case "attachment_mime", "attachmentmime":
            let patterns = arguments
                .compactMap { $0.stringRepresentation }
                .map { $0.trimmingRegexDelimiters() }
            if patterns.isEmpty {
                throw MailFilterError.invalidPredicate("attachment_mime requires patterns")
            }
            return .attachmentMime(patterns: patterns)
        case "folder_exact", "folderexact":
            guard let folder = arguments.first?.stringRepresentation else {
                throw MailFilterError.invalidPredicate("folder_exact(folder)")
            }
            return .folderExact(folder)
        case "folder_prefix", "folderprefix":
            guard let folder = arguments.first?.stringRepresentation else {
                throw MailFilterError.invalidPredicate("folder_prefix(folder)")
            }
            return .folderPrefix(folder)
        case "folder_regex", "foldermatches", "folder_matches":
            guard let pattern = arguments.first?.stringRepresentation else {
                throw MailFilterError.invalidPredicate("folder_regex(pattern)")
            }
            return .folderRegex(pattern)
        case "vip":
            let expected: Bool
            if let stringValue = arguments.first?.stringRepresentation {
                expected = (stringValue as NSString).boolValue
            } else {
                expected = true
            }
            return .vip(expected)
        case "list_unsubscribe", "listunsubscribe":
            let expected: Bool
            if let stringValue = arguments.first?.stringRepresentation {
                expected = (stringValue as NSString).boolValue
            } else {
                expected = true
            }
            return .listUnsubscribe(expected)
        case "date_range", "daterange":
            guard let first = arguments.first?.stringRepresentation else {
                throw MailFilterError.invalidPredicate("date_range expects at least one argument")
            }
            if arguments.count == 1 {
                return .date(.range(DateRangeSpecifier(start: .relativeOrAbsolute(value: first), end: nil)))
            } else {
                guard let second = arguments[1].stringRepresentation else {
                    throw MailFilterError.invalidPredicate("date_range second argument must be string")
                }
                return .date(.range(DateRangeSpecifier(start: .relativeOrAbsolute(value: first),
                                                       end: .relativeOrAbsolute(value: second))))
            }
        case "date_between", "datebetween":
            guard arguments.count >= 2,
                  let start = arguments[0].stringRepresentation,
                  let end = arguments[1].stringRepresentation else {
                throw MailFilterError.invalidPredicate("date_between(start, end)")
            }
            return .date(.between(.relativeOrAbsolute(value: start), .relativeOrAbsolute(value: end)))
        case "date_after", "dateafter":
            guard let value = arguments.first?.stringRepresentation else {
                throw MailFilterError.invalidPredicate("date_after(value)")
            }
            return .date(.comparison(.after, .relativeOrAbsolute(value: value)))
        case "date_before", "datebefore":
            guard let value = arguments.first?.stringRepresentation else {
                throw MailFilterError.invalidPredicate("date_before(value)")
            }
            return .date(.comparison(.before, .relativeOrAbsolute(value: value)))
        case "date_on_or_after", "dateonorafter":
            guard let value = arguments.first?.stringRepresentation else {
                throw MailFilterError.invalidPredicate("date_on_or_after(value)")
            }
            return .date(.comparison(.onOrAfter, .relativeOrAbsolute(value: value)))
        case "date_on_or_before", "dateonorbefore":
            guard let value = arguments.first?.stringRepresentation else {
                throw MailFilterError.invalidPredicate("date_on_or_before(value)")
            }
            return .date(.comparison(.onOrBefore, .relativeOrAbsolute(value: value)))
        default:
            throw MailFilterError.invalidPredicate("Unknown predicate '\(name)'")
        }
    }
}

// MARK: - Token Support Helpers

extension MailFilterFieldReference {
    fileprivate func values(for message: EmailFilterMessageContext) -> [String] {
        switch self {
        case .subject:
            return [message.subject]
        case .body:
            return [message.bodyPlaintext]
        case .htmlBody:
            if let html = message.bodyHTML { return [html] }
            return []
        case .from:
            return message.from
        case .to:
            return message.to
        case .cc:
            return message.cc
        case .bcc:
            return message.bcc
        case .participants:
            return message.from + message.to + message.cc + message.bcc
        case .folder:
            if let folder = message.folderPath { return [folder] }
            return []
        case .header(let name):
            let normalized = name.lowercased()
            if let direct = message.headers[name] {
                return [direct]
            }
            if let value = message.headers.first(where: { $0.key.lowercased() == normalized })?.value {
                return [value]
            }
            return []
        }
    }
}

// MARK: - Date Expression Normalization

private enum DateExpressionNormalizer {
    static func normalize(_ input: String) -> String {
        var output = input
        
        // date in last <value>
        let lastPattern = try! NSRegularExpression(pattern: #"date\s+in\s+last\s+([0-9]+(?:\s*[a-zA-Z]+)?)"#, options: [.caseInsensitive])
        output = lastPattern.stringByReplacingMatches(in: output,
                                                      options: [],
                                                      range: NSRange(location: 0, length: output.utf16.count),
                                                      withTemplate: "date_range('-$1')")
        
        // date between X and Y
        let betweenPattern = try! NSRegularExpression(pattern: #"date\s+between\s+([^\s]+)\s+and\s+([^\s)]+)"#, options: [.caseInsensitive])
        output = betweenPattern.stringByReplacingMatches(in: output,
                                                         options: [],
                                                         range: NSRange(location: 0, length: output.utf16.count),
                                                         withTemplate: "date_between('$1','$2')")
        
        // date >= value
        let comparisonReplacements: [(pattern: String, template: String)] = [
            (#"date\s*>=\s*([^\s)]+)"#, "date_on_or_after('$1')"),
            (#"date\s*<=\s*([^\s)]+)"#, "date_on_or_before('$1')"),
            (#"date\s*>\s*([^\s)]+)"#, "date_after('$1')"),
            (#"date\s*<\s*([^\s)]+)"#, "date_before('$1')"),
            (#"date\s+since\s+([^\s)]+)"#, "date_on_or_after('$1')")
        ]
        
        for replacement in comparisonReplacements {
            let regex = try! NSRegularExpression(pattern: replacement.pattern, options: [.caseInsensitive])
            output = regex.stringByReplacingMatches(in: output,
                                                    options: [],
                                                    range: NSRange(location: 0, length: output.utf16.count),
                                                    withTemplate: replacement.template)
        }
        
        return output
    }
}

// MARK: - Source Loading

public struct MailFilterDocument: Codable {
    public var expressions: [MailFilterExpression]
    public var combinationMode: MailFilterCombinationMode?
    public var defaultAction: MailFilterDefaultAction?
    public var prefilter: MailPrefilterConfig?
    
    enum CodingKeys: String, CodingKey {
        case combinationMode = "combination_mode"
        case defaultAction = "default_action"
        case filters
        case filter
        case expressions
        case prefilter
    }
    
    public init(expressions: [MailFilterExpression] = [],
                combinationMode: MailFilterCombinationMode? = nil,
                defaultAction: MailFilterDefaultAction? = nil,
                prefilter: MailPrefilterConfig? = nil) {
        self.expressions = expressions
        self.combinationMode = combinationMode
        self.defaultAction = defaultAction
        self.prefilter = prefilter
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        combinationMode = try container.decodeIfPresent(MailFilterCombinationMode.self, forKey: .combinationMode)
        defaultAction = try container.decodeIfPresent(MailFilterDefaultAction.self, forKey: .defaultAction)
        prefilter = try container.decodeIfPresent(MailPrefilterConfig.self, forKey: .prefilter)
        
        if let expressions = try container.decodeIfPresent([MailFilterExpression].self, forKey: .filters) {
            self.expressions = expressions
        } else if let expressions = try container.decodeIfPresent([MailFilterExpression].self, forKey: .expressions) {
            self.expressions = expressions
        } else if let single = try container.decodeIfPresent(MailFilterExpression.self, forKey: .filter) {
            self.expressions = [single]
        } else {
            self.expressions = []
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let combinationMode {
            try container.encode(combinationMode, forKey: .combinationMode)
        }
        if let defaultAction {
            try container.encode(defaultAction, forKey: .defaultAction)
        }
        if let prefilter {
            try container.encode(prefilter, forKey: .prefilter)
        }
        try container.encode(expressions, forKey: .filters)
    }
}

private extension MailFilterDocument {
    var hasContent: Bool {
        return expressions.isEmpty == false
            || combinationMode != nil
            || defaultAction != nil
            || prefilter != nil
    }
}

private struct MailFilterSourceLoader {
    let fileManager: FileManager
    
    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }
    
    func expandTilde(in path: String) -> String {
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        return path
    }
    
    func fileExists(at path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }
    
    func loadDocument(at path: String) throws -> MailFilterDocument {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let content = String(data: data, encoding: .utf8) ?? ""
        return try loadDocument(from: content, presumedName: path)
    }
    
    func loadDocument(from content: String, presumedName: String) throws -> MailFilterDocument {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return MailFilterDocument()
        }
        
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let jsonData = trimmed.data(using: .utf8) {
                let decoder = JSONDecoder()
                if let document = try? decoder.decode(MailFilterDocument.self, from: jsonData), document.hasContent {
                    return document
                }
                if let expressions = try? decoder.decode([MailFilterExpression].self, from: jsonData) {
                    return MailFilterDocument(expressions: expressions)
                }
                if let expression = try? decoder.decode(MailFilterExpression.self, from: jsonData) {
                    return MailFilterDocument(expressions: [expression])
                }
            }
        }
        
        // Attempt YAML decode
        do {
            let decoder = YAMLDecoder()
            return try decoder.decode(MailFilterDocument.self, from: Data(trimmed.utf8))
        } catch {
            let decoder = YAMLDecoder()
            if let expressions = try? decoder.decode([MailFilterExpression].self, from: Data(trimmed.utf8)) {
                return MailFilterDocument(expressions: expressions)
            }
            if let expression = try? decoder.decode(MailFilterExpression.self, from: Data(trimmed.utf8)) {
                return MailFilterDocument(expressions: [expression])
            }
            // Maybe raw expression (DSL string)
            do {
                let expression = try MailFilterDSLParser.parse(trimmed)
                return MailFilterDocument(expressions: [expression])
            } catch {
                throw MailFilterError.unsupportedFormat("Unable to parse filters from \(presumedName)")
            }
        }
    }
}

// MARK: - Utilities

private extension String {
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func trimmingRegexDelimiters() -> String {
        guard count >= 2 else { return self }
        if hasPrefix("/") && hasSuffix("/") {
            return String(dropFirst().dropLast())
        }
        return self
    }
}

// MARK: - Folder Hint Extraction

private struct FolderPredicateCollection {
    var exact: Set<String> = []
    var prefixes: Set<String> = []
    
    var isRestrictive: Bool {
        return !exact.isEmpty || !prefixes.isEmpty
    }
    
    func merging(_ other: FolderPredicateCollection) -> FolderPredicateCollection {
        var merged = self
        merged.exact.formUnion(other.exact)
        merged.prefixes.formUnion(other.prefixes)
        return merged
    }
    
    func allPrefixes() -> [String] {
        let combined = exact.union(prefixes)
        return Array(combined)
    }
}

private extension MailFilterExpression {
    func collectFolderPredicates() -> FolderPredicateCollection? {
        return collectFolderPredicatesInternal()
    }
    
    func collectFolderPredicatesInternal() -> FolderPredicateCollection? {
        switch self {
        case .predicate(let predicate):
            switch predicate {
            case .folderExact(let folder):
                var collection = FolderPredicateCollection()
                collection.exact.insert(folder.lowercased())
                return collection
            case .folderPrefix(let prefix):
                var collection = FolderPredicateCollection()
                collection.prefixes.insert(prefix.lowercased())
                return collection
            default:
                return FolderPredicateCollection()
            }
        case .and(let expressions):
            var aggregate = FolderPredicateCollection()
            var foundRestrictive = false
            for expression in expressions {
                guard let partial = expression.collectFolderPredicatesInternal() else {
                    continue
                }
                if partial.isRestrictive {
                    aggregate = aggregate.merging(partial)
                    foundRestrictive = true
                }
            }
            return foundRestrictive ? aggregate : FolderPredicateCollection()
        case .or, .not:
            return nil
        }
    }
}
