import Foundation
import NaturalLanguage
import OSLog

/// Natural Language entity extraction service for macOS
public actor EntityService {
    private let logger = Logger(subsystem: "com.haven.hostagent", category: "entity")
    private let enabledTypes: Set<EntityType>
    private let minConfidence: Float
    
    public init(enabledTypes: [EntityType] = EntityType.allCases, 
                minConfidence: Float = 0.0) {
        self.enabledTypes = Set(enabledTypes)
        self.minConfidence = minConfidence
    }
    
    /// Extract entities from text
    public func extractEntities(from text: String, 
                               enabledTypes: [EntityType]? = nil,
                               minConfidence: Float? = nil) async throws -> EntityExtractionResult {
        let startTime = Date()
        
        // Use provided parameters or fall back to instance defaults
        let effectiveTypes = enabledTypes.map { Set($0) } ?? self.enabledTypes
        let effectiveMinConfidence = minConfidence ?? self.minConfidence
        
        logger.info("Starting entity extraction: text_length=\(text.count), enabled_types=\(effectiveTypes.count)")
        
        // Extract entities using NaturalLanguage framework
        let entities = try await performNLExtraction(
            text: text,
            enabledTypes: effectiveTypes,
            minConfidence: effectiveMinConfidence
        )
        
        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
        
        logger.info("Entity extraction complete: entities_found=\(entities.count), elapsed_ms=\(elapsed)")
        
        return EntityExtractionResult(
            entities: entities,
            totalEntities: entities.count,
            timingsMs: ["total": elapsed]
        )
    }
    
    private func performNLExtraction(
        text: String,
        enabledTypes: Set<EntityType>,
        minConfidence: Float
    ) async throws -> [Entity] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var entities: [Entity] = []
                
                // Create tagger with appropriate schemes
                let tagger = NLTagger(tagSchemes: [.nameType])
                tagger.string = text
                
                // Enumerate tags
                let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
                
                tagger.enumerateTags(in: text.startIndex..<text.endIndex, 
                                    unit: .word,
                                    scheme: .nameType, 
                                    options: options) { tag, range in
                    
                    guard let tag = tag else { return true }
                    
                    // Map NLTag to our EntityType (static function)
                    guard let entityType = Self.mapNLTagToEntityType(tag),
                          enabledTypes.contains(entityType) else {
                        return true
                    }
                    
                    let entityText = String(text[range])
                    
                    // Calculate character range
                    let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
                    let endOffset = text.distance(from: text.startIndex, to: range.upperBound)
                    
                    // NLTagger doesn't provide confidence scores directly
                    // We use a fixed confidence of 1.0 for all matches
                    let confidence: Float = 1.0
                    
                    // Apply confidence filter
                    guard confidence >= minConfidence else { return true }
                    
                    let entity = Entity(
                        text: entityText,
                        type: entityType,
                        range: [startOffset, endOffset],
                        confidence: confidence
                    )
                    
                    entities.append(entity)
                    
                    return true
                }
                
                continuation.resume(returning: entities)
            }
        }
    }
    
    private static func mapNLTagToEntityType(_ tag: NLTag) -> EntityType? {
        switch tag {
        case .personalName:
            return .person
        case .placeName:
            return .place
        case .organizationName:
            return .organization
        default:
            return nil
        }
    }
    
    public func healthCheck() -> EntityHealth {
        return EntityHealth(
            available: true,
            supportedTypes: EntityType.allCases.map { $0.rawValue },
            nlVersion: "macOS-\(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
    }
}

// MARK: - Data Types

public enum EntityType: String, Codable, CaseIterable {
    case person
    case organization
    case place
    case date
    case time
    case address
}

public struct Entity: Codable {
    public let text: String
    public let type: EntityType
    public let range: [Int]
    public let confidence: Float
    
    public init(text: String, type: EntityType, range: [Int], confidence: Float) {
        self.text = text
        self.type = type
        self.range = range
        self.confidence = confidence
    }
}

public struct EntityExtractionResult: Codable {
    public let entities: [Entity]
    public let totalEntities: Int
    public let timingsMs: [String: Int]
    
    enum CodingKeys: String, CodingKey {
        case entities
        case totalEntities = "total_entities"
        case timingsMs = "timings_ms"
    }
    
    public init(entities: [Entity], totalEntities: Int, timingsMs: [String: Int]) {
        self.entities = entities
        self.totalEntities = totalEntities
        self.timingsMs = timingsMs
    }
}

public struct EntityHealth: Codable {
    public let available: Bool
    public let supportedTypes: [String]
    public let nlVersion: String
    
    enum CodingKeys: String, CodingKey {
        case available
        case supportedTypes = "supported_types"
        case nlVersion = "nl_version"
    }
    
    public init(available: Bool, supportedTypes: [String], nlVersion: String) {
        self.available = available
        self.supportedTypes = supportedTypes
        self.nlVersion = nlVersion
    }
}

public enum EntityError: Error, LocalizedError {
    case noInput
    case extractionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .noInput:
            return "No text provided for entity extraction"
        case .extractionFailed(let details):
            return "Entity extraction failed: \(details)"
        }
    }
}
