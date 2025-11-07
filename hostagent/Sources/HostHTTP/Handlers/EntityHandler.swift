import Foundation
import HavenCore
import Entity

/// Handler for entity extraction endpoint
public struct EntityHandler {
    private let config: HavenConfig
    private let entityService: EntityService
    private let logger = HavenLogger(category: "entity-handler")
    
    public init(config: HavenConfig) {
        self.config = config
        
        // Parse entity types from config
        let enabledTypes = config.modules.entity.types.compactMap { typeString -> EntityType? in
            EntityType(rawValue: typeString)
        }
        
        self.entityService = EntityService(
            enabledTypes: enabledTypes.isEmpty ? EntityType.allCases : enabledTypes,
            minConfidence: config.modules.entity.minConfidence
        )
    }
    
    public func handle(request: HTTPRequest, context: RequestContext) async -> HTTPResponse {
        
        // Parse request body
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            logger.warning("Invalid request body")
            return HTTPResponse.badRequest(message: "Invalid request body - expected JSON")
        }
        
        // Extract parameters
        guard let text = json["text"] as? String, !text.isEmpty else {
            logger.warning("No text provided")
            return HTTPResponse.badRequest(message: "text field is required and must not be empty")
        }
        
        let enabledTypesParam = (json["enabled_types"] as? [String])?.compactMap { EntityType(rawValue: $0) }
        let minConfidenceParam = json["min_confidence"] as? Float
        
        // Perform entity extraction
        do {
            let result = try await entityService.extractEntities(
                from: text,
                enabledTypes: enabledTypesParam,
                minConfidence: minConfidenceParam
            )
            
            logger.info("Entity extraction completed successfully: entities_found=\(result.totalEntities)")
            
            // Encode result
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let resultData = try encoder.encode(result)
            
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: resultData
            )
        } catch {
            logger.error("Entity extraction failed: \(error.localizedDescription)")
            return HTTPResponse.internalError(message: "Entity extraction failed: \(error.localizedDescription)")
        }
    }
}
