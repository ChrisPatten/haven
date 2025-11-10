import Foundation
import OCR
import Face
import Entity
import Caption
import HavenCore

/// Protocol for enrichment orchestrator
public protocol EnrichmentOrchestrator: Sendable {
    /// Enrich a document using available services
    func enrich(_ document: CollectorDocument) async throws -> EnrichedDocument
}

/// Error types for enrichment
public enum EnrichmentError: LocalizedError {
    case imageDataUnavailable
    case enrichmentFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .imageDataUnavailable:
            return "Image data is not available for enrichment"
        case .enrichmentFailed(let message):
            return "Enrichment failed: \(message)"
        }
    }
}

/// Document enrichment orchestrator that coordinates enrichment services
public actor DocumentEnrichmentOrchestrator: EnrichmentOrchestrator {
    private let ocrService: OCRService?
    private let faceService: FaceService?
    private let entityService: EntityService?
    private let captionService: CaptionService?
    private let ocrConfig: OCRModuleConfig
    private let faceConfig: FaceModuleConfig
    private let entityConfig: EntityModuleConfig
    private let captionConfig: CaptionModuleConfig
    private let logger = HavenLogger(category: "enrichment-orchestrator")
    
    public init(
        ocrService: OCRService?,
        faceService: FaceService?,
        entityService: EntityService?,
        captionService: CaptionService?,
        ocrConfig: OCRModuleConfig,
        faceConfig: FaceModuleConfig,
        entityConfig: EntityModuleConfig,
        captionConfig: CaptionModuleConfig
    ) {
        self.ocrService = ocrService
        self.faceService = faceService
        self.entityService = entityService
        self.captionService = captionService
        self.ocrConfig = ocrConfig
        self.faceConfig = faceConfig
        self.entityConfig = entityConfig
        self.captionConfig = captionConfig
    }
    
    public func enrich(_ document: CollectorDocument) async throws -> EnrichedDocument {
        let enrichmentStartTime = Date()
        
        // Enrich each image attachment independently
        var imageEnrichments: [ImageEnrichment] = []
        for image in document.images {
            // Build enrichment values incrementally
            var ocrResult: OCRResult? = nil
            var faceResult: FaceDetectionResult? = nil
            var captionText: String? = nil
            
            // OCR for this image (using existing OCRService)
            if ocrConfig.enabled, let ocrService = ocrService {
                do {
                    ocrResult = try await performOCR(image: image, ocrService: ocrService, config: ocrConfig)
                } catch {
                    logger.warning("OCR enrichment failed for image", metadata: [
                        "image_hash": image.hash,
                        "error": error.localizedDescription
                    ])
                }
            }
            
            // Face detection for this image (using existing FaceService)
            if faceConfig.enabled, let faceService = faceService {
                do {
                    faceResult = try await performFaceDetection(image: image, faceService: faceService, config: faceConfig)
                } catch {
                    logger.warning("Face detection enrichment failed for image", metadata: [
                        "image_hash": image.hash,
                        "error": error.localizedDescription
                    ])
                }
            }
            
            // Captioning for this image (using CaptionService - not email-specific)
            // Note: Caption data is NOT enriched further (no NER on captions)
            // Pass OCR text if available to improve caption quality
            // Only proceed if captioning is enabled AND service is available
            // Skip silently if disabled (no logging per image to avoid noise)
            if captionConfig.enabled, let captionService = captionService {
                do {
                    let ocrTextForCaption = ocrResult?.ocrText
                    logger.debug("Attempting to generate caption for image", metadata: [
                        "image_hash": image.hash,
                        "has_ocr_text": ocrTextForCaption != nil && !ocrTextForCaption!.isEmpty
                    ])
                    captionText = try await performCaptioning(image: image, captionService: captionService, ocrText: ocrTextForCaption)
                    if let caption = captionText {
                        logger.info("Caption generated successfully", metadata: [
                            "image_hash": image.hash,
                            "caption_length": String(caption.count),
                            "caption_preview": String(caption.prefix(50))
                        ])
                    } else {
                        logger.warning("Caption generation returned nil", metadata: [
                            "image_hash": image.hash
                        ])
                    }
                } catch {
                    logger.warning("Caption enrichment failed for image", metadata: [
                        "image_hash": image.hash,
                        "error": error.localizedDescription
                    ])
                }
            } else if captionConfig.enabled {
                // Config says enabled but service is nil - this shouldn't happen
                logger.warning("Caption config enabled but CaptionService is nil", metadata: [
                    "image_hash": image.hash
                ])
            }
            
            // Create ImageEnrichment with all enrichment results
            let imageEnrichment = ImageEnrichment(
                ocr: ocrResult,
                faces: faceResult,
                caption: captionText,
                enrichmentTimestamp: enrichmentStartTime
            )
            
            imageEnrichments.append(imageEnrichment)
        }
        
        // Enrich primary document text content
        // Include OCR text from all images for entity extraction
        var textForNER = document.content
        for imageEnrichment in imageEnrichments {
            if let ocrResult = imageEnrichment.ocr, !ocrResult.ocrText.isEmpty {
                textForNER += "\n" + ocrResult.ocrText
            }
        }
        
        var documentEnrichment: DocumentEnrichment?
        if entityConfig.enabled, let entityService = entityService, !textForNER.isEmpty {
            do {
                // Convert entity config types to EntityType enum
                let entityTypes = entityConfig.types.compactMap { EntityType(rawValue: $0) }
                let result = try await entityService.extractEntities(
                    from: textForNER,
                    enabledTypes: entityTypes.isEmpty ? nil : entityTypes,
                    minConfidence: entityConfig.minConfidence
                )
                documentEnrichment = DocumentEnrichment(
                    entities: result.entities,
                    enrichmentTimestamp: enrichmentStartTime
                )
            } catch {
                logger.warning("Entity extraction enrichment failed", metadata: ["error": error.localizedDescription])
                documentEnrichment = DocumentEnrichment(entities: nil, enrichmentTimestamp: enrichmentStartTime)
            }
        }
        
        return EnrichedDocument(
            base: document,
            documentEnrichment: documentEnrichment,
            imageEnrichments: imageEnrichments
        )
    }
    
    private func performOCR(
        image: ImageAttachment,
        ocrService: OCRService,
        config: OCRModuleConfig
    ) async throws -> OCRResult {
        // Load image data temporarily for processing (not retained after enrichment)
        let imageData = try await loadImageDataTemporarily(image: image)
        
        return try await ocrService.processImage(
            path: nil,
            data: imageData,
            recognitionLevel: config.recognitionLevel,
            includeLayout: config.includeLayout
        )
    }
    
    private func performFaceDetection(
        image: ImageAttachment,
        faceService: FaceService,
        config: FaceModuleConfig
    ) async throws -> FaceDetectionResult {
        // Load image data temporarily for processing (not retained after enrichment)
        let imageData = try await loadImageDataTemporarily(image: image)
        
        return try await faceService.detectFaces(
            imageData: imageData,
            includeLandmarks: config.includeLandmarks
        )
    }
    
    private func performCaptioning(
        image: ImageAttachment,
        captionService: CaptionService,
        ocrText: String? = nil
    ) async throws -> String? {
        // Load image data temporarily for processing (not retained after enrichment)
        let imageData = try await loadImageDataTemporarily(image: image)
        
        let caption = try await captionService.generateCaption(imageData: imageData, ocrText: ocrText)
        // Note: Caption is NOT enriched further (no NER on captions)
        return caption
    }
    
    // Helper methods to load image data temporarily (implementation depends on storage strategy)
    private func loadImageDataTemporarily(image: ImageAttachment) async throws -> Data {
        // First try temporary data if available
        if let temporaryData = image.temporaryData {
            return temporaryData
        }
        
        // Then try temporary path
        if let temporaryPath = image.temporaryPath {
            guard FileManager.default.fileExists(atPath: temporaryPath) else {
                throw EnrichmentError.imageDataUnavailable
            }
            return try Data(contentsOf: URL(fileURLWithPath: temporaryPath))
        }
        
        // If neither is available, we can't process the image
        throw EnrichmentError.imageDataUnavailable
    }
}

