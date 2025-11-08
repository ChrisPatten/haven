# HostAgent Architecture Cleanup Design Proposal

## Overview

This document proposes a refactoring of the HostAgent architecture to separate concerns and create a cleaner, more maintainable data flow. The goal is to introduce explicit **Enrichment** and **Submission** layers while keeping **Collectors** focused on their core responsibility of data ingestion.

## Current State

### Architecture Issues

1. **Mixed Responsibilities**: Collectors currently handle both data collection and enrichment (e.g., OCR, captioning, NER)
2. **Scattered Enrichment Logic**: Enrichment capabilities (OCR, face detection, NER, captioning) are embedded within collectors rather than being orchestrated centrally
3. **Direct Gateway Submission**: Collectors directly submit to the gateway, making batching and retry logic harder to manage
4. **Inconsistent Flow**: Contacts bypass enrichment but use the same submission path, creating confusion

### Current Components

- **Collectors**: `EmailCollector`, `LocalFSCollector`, `ContactsHandler`, `IMessageHandler`
- **Collection Modules** (shared, used during collection):
  - `EmailBodyExtractor` (`hostagent/Sources/Email/EmailBodyExtractor.swift`) - HTML to markdown conversion (to be generalized as `TextExtractor`)
  - `EmailImageExtractor` (`hostagent/Sources/Email/EmailImageExtractor.swift`) - Image extraction from email (to be generalized as `ImageExtractor`)
- **Enrichment Services** (existing, to be leveraged):
  - `OCRService` (`hostagent/Sources/OCR/OCRService.swift`) - Vision framework OCR
  - `FaceService` (`hostagent/Sources/Face/FaceService.swift`) - Vision framework face detection
  - `EntityService` (`hostagent/Sources/Entity/EntityService.swift`) - NaturalLanguage framework NER
  - `CaptionService` (to be created) - Image caption generation/extraction (not email-specific)
- **Configuration**: `ModulesConfig` in `HavenConfig` (`hostagent/Sources/HavenCore/Config.swift`)
  - `OCRModuleConfig`, `FaceModuleConfig`, `EntityModuleConfig` already defined
  - `CaptionModuleConfig` to be added
- **Submission**: `GatewaySubmissionClient` (embedded in collectors)

## Proposed Architecture

### High-Level Flow

```
┌─────────────┐
│  Collector  │ ──┐
└─────────────┘   │
                  │ Raw Document
┌─────────────┐   │
│  Collector  │ ──┤
└─────────────┘   │
                  ▼
         ┌─────────────────┐
         │   Enrichment    │ (Optional - collectors decide to skip)
         │   Orchestrator  │
         └─────────────────┘
                  │ Enriched Document
                  ▼
         ┌─────────────────┐
         │    Submitter    │
         │   (Batching)    │
         └─────────────────┘
                  │ Batched Documents
                  ▼
         ┌─────────────────┐
         │  Gateway API    │
         └─────────────────┘
```

### Component Responsibilities

#### 1. Collectors (Unchanged)

**Responsibility**: Ingest data from various sources and convert to a standard document format.

**Tasks**:
- Read from source (iMessage, email, filesystem, contacts)
- Decode content (MIME for email, file content for files)
- Call shared modules for text/image extraction:
  - **Text Extraction**: Use shared `TextExtractor` module to convert HTML/rich text to markdown
  - **Image Extraction**: Use shared `ImageExtractor` module to extract images from content
- Build initial document payload with basic metadata
- Pass documents to Enrichment (or Submitter for contacts)

**Shared Collection Modules** (used by collectors, not enrichment):
- `TextExtractor` - Centralized module for converting HTML/rich text to markdown (generalized from `EmailBodyExtractor`)
- `ImageExtractor` - Centralized module for extracting images from content (generalized from `EmailImageExtractor`)

**Output**: `CollectorDocument` - A standardized document structure containing:
- Content (markdown text from TextExtractor)
- Source metadata (sourceType, sourceId, timestamps)
- Images (array of image attachments extracted by ImageExtractor, ready for enrichment)
- Basic metadata (hashes, mime types)

**Important Notes**:
- **File Collector**: Extracts text and images from files but does NOT save the actual files themselves
- **Image Retention**: Image files themselves are NOT retained - only metadata and enrichment data are kept
- **Image Extraction**: Image extraction happens during collection and is separate from enrichment. Extracted images are then available for OCR, Face detection, and Captioning during enrichment
- **Multiple Images**: A document may have multiple image attachments, each of which will be enriched independently

#### 2. Enrichment Orchestrator (New)

**Responsibility**: Orchestrate progressive enhancement of document metadata using available services.

**Tasks**:
- Accept documents from collectors (with images already extracted)
- Determine which enrichment steps are needed based on document type and content
- Coordinate enrichment services on extracted images and text:
  - **OCR**: Extract text from images (using `OCRService`)
  - **Face Detection**: Detect faces in images (using `FaceService`)
  - **NER**: Extract named entities from text (using `EntityService`)
  - **Captioning**: Generate/extract image captions (using `CaptionService`)
- Progressively enhance document metadata
- Pass enriched documents to Submitter

**Enrichment Flow**:
```
CollectorDocument (with extracted images from collection)
  │
  ├─> For each image attachment (enriched independently):
  │   ├─> OCR → Extract text from image → Store in imageEnrichments[i].ocr
  │   ├─> Face Detection → Detect faces → Store in imageEnrichments[i].faces
  │   └─> Captioning → Generate caption → Store in imageEnrichments[i].caption
  │       (Note: Caption is NOT enriched further - no NER on captions)
  │
  └─> For primary document text:
      └─> NER → Extract entities from text + all OCR text → Store in documentEnrichment.entities
          (Includes OCR text from all images, but NOT caption text)
```

**Important**:
- Each image has its own enrichment data (OCR, faces, caption)
- Primary document has its own enrichment data (entities from text + OCR text)
- Image files are NOT retained - only metadata and enrichment results
- Caption data is final and does NOT go through NER or other enrichment

**Output**: `EnrichedDocument` - Original document with enhanced metadata:
- Original content and metadata
- **Primary document enrichment**:
  - `enrichment.entities`: Extracted named entities from text content (including OCR'd text from images)
- **Per-image enrichment** (array, one per image attachment):
  - `enrichment.ocr`: OCR results for this image
  - `enrichment.faces`: Face detection results for this image
  - `enrichment.caption`: Caption for this image
  - Image metadata (hash, mime type, dimensions, etc.)

**Important Notes**:
- Each image attachment has its own enrichment data (OCR, faces, caption)
- The primary document has its own enrichment data (entities from text + OCR text)
- **Caption data is NOT enriched further** - captions are final and do not go through NER or other enrichment steps
- Image files themselves are not retained - only metadata and enrichment results are kept

**Configuration**: Enrichment settings are configured per-collector in Haven.app and persisted as plist. Each collector decides whether to skip enrichment for its documents.

**Integration with Existing Config**: The orchestrator uses the existing `ModulesConfig` structure from `HavenConfig`:
- `modules.ocr` → `OCRModuleConfig` (enabled, languages, timeoutMs, recognitionLevel, includeLayout)
- `modules.face` → `FaceModuleConfig` (enabled, minFaceSize, minConfidence, includeLandmarks)
- `modules.entity` → `EntityModuleConfig` (enabled, types, minConfidence)
- `modules.caption` → `CaptionModuleConfig` (to be added: enabled, methods, etc.)

These configurations are already defined (or will be) in `hostagent/Sources/HavenCore/Config.swift` and loaded from YAML config files.

**Collection vs Enrichment**: 
- **Collection-time**: Text extraction (HTML→markdown) and image extraction happen during collection using shared modules
- **Enrichment-time**: OCR, Face detection, Captioning, and NER happen during enrichment on already-extracted content

#### 3. Submitter Service (New)

**Responsibility**: Batch documents and submit to the Gateway API.

**Tasks**:
- Accept documents from Enrichment or Collectors (for contacts)
- Accept batches of documents (whatever batch size collectors pass in)
- Handle retry logic and error recovery
- Manage idempotency keys
- Submit to Gateway API endpoints:
  - `/v1/ingest` for documents
  - `/v1/ingest/file` for file attachments
  - `/catalog/contacts/ingest` for contacts

**Features**:
- Accepts batches of any size from collectors
- Retry with exponential backoff
- Error handling and reporting

**Output**: Submission results (success/failure per document)

### Special Cases

#### Contacts

Contacts **skip enrichment** entirely:
- `ContactsHandler` → `Submitter` → Gateway
- No OCR, face detection, NER, or captioning needed
- Direct submission to `/catalog/contacts/ingest`

#### File Attachments

File attachments from LocalFS or email:
- Can go through enrichment (OCR, face detection)
- Submitted via `/v1/ingest/file` endpoint
- Metadata includes enrichment results

## Implementation Details

### Document Types

```swift
// Base document structure from collectors
public struct CollectorDocument: Sendable {
    let content: String  // Markdown text extracted from source
    let sourceType: String
    let sourceId: String
    let metadata: DocumentMetadata
    let images: [ImageAttachment]  // Array of extracted images (files not retained, only metadata)
    let contentType: DocumentContentType  // email, imessage, localfs, contact
}

// Image attachment (file not retained, only metadata)
public struct ImageAttachment: Sendable {
    let hash: String  // SHA-256 hash of image
    let mimeType: String
    let dimensions: ImageDimensions?  // width, height
    let extractedAt: Date
    // Note: Actual image file data is NOT stored
}

// Enriched document with progressive enhancements
public struct EnrichedDocument: Sendable {
    let base: CollectorDocument
    let documentEnrichment: DocumentEnrichment?  // Enrichment for primary document
    let imageEnrichments: [ImageEnrichment]  // One per image, parallel to base.images array
}

// Enrichment for the primary document (text content)
public struct DocumentEnrichment: Sendable {
    let entities: [Entity]?  // Entities extracted from text + OCR text from all images
    let enrichmentTimestamp: Date
}

// Enrichment for a single image attachment
public struct ImageEnrichment: Sendable {
    let ocr: OCRResult?  // OCR results for this image
    let faces: FaceDetectionResult?  // Face detection results for this image
    let caption: String?  // Caption for this image (NOT enriched further)
    let enrichmentTimestamp: Date
}
```

### Enrichment Orchestrator Interface

The orchestrator uses existing enrichment services from hostagent:
- `OCRService` (from `hostagent/Sources/OCR/OCRService.swift`) - OCR on extracted images
- `FaceService` (from `hostagent/Sources/Face/FaceService.swift`) - Face detection on extracted images
- `EntityService` (from `hostagent/Sources/Entity/EntityService.swift`) - NER on text content
- `CaptionService` (to be created) - Captioning on extracted images (not email-specific)

**Note**: Images are extracted during collection using shared `ImageExtractor` module. The orchestrator operates on already-extracted images, not raw content.

Configuration is integrated with existing `ModulesConfig` structure:
- `OCRModuleConfig` (enabled, languages, timeoutMs, recognitionLevel, includeLayout)
- `FaceModuleConfig` (enabled, minFaceSize, minConfidence, includeLandmarks)
- `EntityModuleConfig` (enabled, types, minConfidence)
- `CaptionModuleConfig` (to be added: enabled, methods, etc.)

```swift
public protocol EnrichmentOrchestrator: Sendable {
    /// Enrich a document using available services
    func enrich(_ document: CollectorDocument) async throws -> EnrichedDocument
}

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
            var imageEnrichment = ImageEnrichment(
                ocr: nil,
                faces: nil,
                caption: nil,
                enrichmentTimestamp: enrichmentStartTime
            )
            
            // OCR for this image (using existing OCRService)
            if ocrConfig.enabled, let ocrService = ocrService {
                do {
                    // Note: We need image data temporarily for OCR, but don't retain it
                    // In practice, this would be loaded from source, processed, then discarded
                    imageEnrichment.ocr = try await performOCR(image: image, ocrService: ocrService, config: ocrConfig)
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
                    imageEnrichment.faces = try await performFaceDetection(image: image, faceService: faceService, config: faceConfig)
                } catch {
                    logger.warning("Face detection enrichment failed for image", metadata: [
                        "image_hash": image.hash,
                        "error": error.localizedDescription
                    ])
                }
            }
            
            // Captioning for this image (using CaptionService - not email-specific)
            // Note: Caption data is NOT enriched further (no NER on captions)
            if captionConfig.enabled, let captionService = captionService {
                do {
                    imageEnrichment.caption = try await performCaptioning(image: image, captionService: captionService)
                } catch {
                    logger.warning("Caption enrichment failed for image", metadata: [
                        "image_hash": image.hash,
                        "error": error.localizedDescription
                    ])
                }
            }
            
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
        // In practice, this would load from source using image.hash or other identifier
        // For now, assuming we have a way to load image data temporarily
        let imageData = try await loadImageDataTemporarily(image: image)
        defer {
            // Image data is discarded after processing - not retained
        }
        
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
        let imagePath = try await loadImagePathTemporarily(image: image)
        defer {
            // Image file is discarded after processing - not retained
        }
        
        return try await faceService.detectFaces(
            imagePath: imagePath,
            includeLandmarks: config.includeLandmarks
        )
    }
    
    private func performCaptioning(
        image: ImageAttachment,
        captionService: CaptionService
    ) async throws -> String {
        // Load image data temporarily for processing (not retained after enrichment)
        let imageData = try await loadImageDataTemporarily(image: image)
        defer {
            // Image data is discarded after processing - not retained
        }
        
        let caption = try await captionService.generateCaption(imageData: imageData)
        // Note: Caption is NOT enriched further (no NER on captions)
        return caption
    }
    
    // Helper methods to load image data temporarily (implementation depends on storage strategy)
    private func loadImageDataTemporarily(image: ImageAttachment) async throws -> Data {
        // In practice, this would load image from source using image.hash
        // and return data for processing, then discard
        // Implementation depends on how images are temporarily stored during collection
        throw EnrichmentError.imageDataUnavailable
    }
    
    private func loadImagePathTemporarily(image: ImageAttachment) async throws -> String {
        // In practice, this would return temporary path to image file
        // Implementation depends on how images are temporarily stored during collection
        throw EnrichmentError.imageDataUnavailable
    }
}
```

### Submitter Service Interface

```swift
public protocol DocumentSubmitter: Sendable {
    /// Submit a single document
    func submit(_ document: EnrichedDocument) async throws -> SubmissionResult
    
    /// Submit multiple documents (accepts whatever batch size is passed in)
    func submitBatch(_ documents: [EnrichedDocument]) async throws -> [SubmissionResult]
}

public actor BatchDocumentSubmitter: DocumentSubmitter {
    private let gatewayClient: GatewaySubmissionClient
    
    public init(gatewayClient: GatewaySubmissionClient) {
        self.gatewayClient = gatewayClient
    }
    
    public func submit(_ document: EnrichedDocument) async throws -> SubmissionResult {
        // Single document submission - wrap in array and submit
        let results = try await gatewayClient.submitDocumentsBatch(documents: [document])
        return results.first?.toSubmissionResult() ?? SubmissionResult.failure(error: "No result")
    }
    
    public func submitBatch(_ documents: [EnrichedDocument]) async throws -> [SubmissionResult] {
        // Accept whatever batch size collectors pass in
        return try await gatewayClient.submitDocumentsBatch(documents: documents)
    }
}
```

### Collection Flow (Text and Image Extraction)

During collection, collectors use shared modules to extract text and images:

```swift
// Example: EmailCollector collection flow
public func collectAndSubmit(email: EmailMessage) async throws {
    // 1. Decode MIME content (email-specific)
    let mimeContent = decodeMIME(email)
    
    // 2. Extract text using shared TextExtractor module
    let textExtractor = TextExtractor()  // Generalized from EmailBodyExtractor
    let markdownContent = await textExtractor.extractText(from: mimeContent)
    
    // 3. Extract images using shared ImageExtractor module
    let imageExtractor = ImageExtractor()  // Generalized from EmailImageExtractor
    let extractedImages = await imageExtractor.extractImages(from: mimeContent)
    
    // 4. Build base document with extracted content
    let document = CollectorDocument(
        content: markdownContent,
        sourceType: "email",
        sourceId: email.messageId,
        attachments: extractedImages,  // Images ready for enrichment
        // ... other metadata
    )
    
    // 5. Pass to enrichment (or submitter if skipping enrichment)
    // ...
}

// Example: LocalFSCollector collection flow
public func collectAndSubmit(file: URL) async throws {
    // 1. Read file content
    let fileContent = try Data(contentsOf: file)
    
    // 2. Extract text using shared TextExtractor (if HTML/rich text)
    let textExtractor = TextExtractor()
    let markdownContent = await textExtractor.extractText(from: fileContent, mimeType: file.mimeType)
    
    // 3. Extract images using shared ImageExtractor (if file contains images)
    // Note: This extracts image metadata, NOT the actual image files
    let imageExtractor = ImageExtractor()
    let extractedImages = await imageExtractor.extractImages(from: fileContent, mimeType: file.mimeType)
    // extractedImages contains metadata (hash, mime type, dimensions) but NOT file data
    
    // 4. Build base document
    // Note: Actual file is NOT saved - only extracted text and image metadata
    let document = CollectorDocument(
        content: markdownContent,
        sourceType: "localfs",
        sourceId: file.path,
        images: extractedImages,  // Array of ImageAttachment (metadata only, no file data)
        // ... other metadata
    )
    
    // 5. Pass to enrichment
    // Each image in document.images will be enriched independently
    // ...
}
```

**Key Points**:
- Text extraction (HTML→markdown) happens during collection, not enrichment
- Image extraction happens during collection, not enrichment
- Both use shared modules that any collector can call
- **File Collector**: Extracts text and images from files but does NOT save the actual files themselves
- **Image Retention**: Image files themselves are NOT retained - only metadata (hash, mime type, dimensions) and enrichment data are kept
- Extracted images (as metadata) are then available for enrichment (OCR, Face, Captioning)
- Each image attachment gets enriched independently with its own OCR, face detection, and caption data
- Caption data is NOT enriched further (no NER on captions)

### Collector Updates

Collectors will be simplified to focus on collection:

```swift
// EmailCollector simplified
public actor EmailCollector {
    private let enrichmentOrchestrator: EnrichmentOrchestrator?
    private let submitter: DocumentSubmitter
    private let skipEnrichment: Bool  // Configured in Haven.app plist
    
    public init(
        config: HavenConfig,
        gatewayConfig: GatewayConfig,
        authToken: String,
        enrichmentOrchestrator: EnrichmentOrchestrator? = nil,
        submitter: DocumentSubmitter? = nil,
        skipEnrichment: Bool = false  // Loaded from Haven.app plist
    ) {
        // Initialize enrichment orchestrator if not provided and modules are enabled
        if enrichmentOrchestrator == nil && !skipEnrichment {
            let ocrService = config.modules.ocr.enabled ? OCRService(
                timeoutMs: config.modules.ocr.timeoutMs,
                languages: config.modules.ocr.languages,
                recognitionLevel: config.modules.ocr.recognitionLevel,
                includeLayout: config.modules.ocr.includeLayout
            ) : nil
            
            let faceService = config.modules.face.enabled ? FaceService(
                minFaceSize: config.modules.face.minFaceSize,
                minConfidence: config.modules.face.minConfidence,
                includeLandmarks: config.modules.face.includeLandmarks
            ) : nil
            
            let entityService = config.modules.entity.enabled ? EntityService(
                enabledTypes: config.modules.entity.types.compactMap { EntityType(rawValue: $0) },
                minConfidence: config.modules.entity.minConfidence
            ) : nil
            
            let captionService = config.modules.caption.enabled ? CaptionService(
                // Initialize with caption config
            ) : nil
            
            self.enrichmentOrchestrator = DocumentEnrichmentOrchestrator(
                ocrService: ocrService,
                faceService: faceService,
                entityService: entityService,
                captionService: captionService,
                ocrConfig: config.modules.ocr,
                faceConfig: config.modules.face,
                entityConfig: config.modules.entity,
                captionConfig: config.modules.caption
            )
        } else {
            self.enrichmentOrchestrator = enrichmentOrchestrator
        }
        
        // Initialize submitter if not provided
        let gatewayClient = GatewaySubmissionClient(config: gatewayConfig, authToken: authToken)
        self.submitter = submitter ?? BatchDocumentSubmitter(gatewayClient: gatewayClient)
        self.skipEnrichment = skipEnrichment
    }
    
    public func collectAndSubmit(email: EmailMessage) async throws {
        // 1. Build base document
        let document = try await buildDocument(from: email)
        
        // 2. Enrich (if not skipped by collector configuration)
        let enriched: EnrichedDocument
        if !skipEnrichment, let orchestrator = enrichmentOrchestrator {
            enriched = try await orchestrator.enrich(document)
        } else {
            enriched = EnrichedDocument(base: document, enrichment: nil)
        }
        
        // 3. Submit
        _ = try await submitter.submit(enriched)
    }
}

// ContactsHandler simplified
public actor ContactsHandler {
    private let submitter: DocumentSubmitter
    private let skipEnrichment: Bool = true  // Contacts always skip enrichment
    
    public init(submitter: DocumentSubmitter) {
        self.submitter = submitter
    }
    
    public func collectAndSubmit(contact: CNContact) async throws {
        // 1. Build base document (contact)
        let document = try buildDocument(from: contact)
        
        // 2. Skip enrichment (contacts always skip - configured at collector level)
        let enriched = EnrichedDocument(base: document, enrichment: nil)
        
        // 3. Submit directly
        _ = try await submitter.submit(enriched)
    }
}
```

## Migration Strategy

### Phase 1: Extract Submission Logic
1. Create `BatchDocumentSubmitter` service
2. Move batching logic from `GatewaySubmissionClient` to `BatchDocumentSubmitter`
3. Update collectors to use `BatchDocumentSubmitter` instead of direct gateway calls

### Phase 2: Create Enrichment Orchestrator
1. Create `DocumentEnrichmentOrchestrator`
2. Extract enrichment logic from collectors into orchestrator
3. Update collectors to use orchestrator

### Phase 3: Refactor Collectors
1. Simplify collectors to focus on collection only
2. Remove enrichment logic from collectors
3. Update collectors to use new flow: Collect → Enrich → Submit

### Phase 4: Testing & Validation
1. Ensure all collectors work with new architecture
2. Verify enrichment is applied correctly
3. Verify contacts skip enrichment
4. Test batching and submission

## Benefits

1. **Separation of Concerns**: Each component has a single, clear responsibility
2. **Reusability**: Enrichment logic can be reused across all collectors
3. **Testability**: Each component can be tested independently
4. **Maintainability**: Changes to enrichment or submission logic don't affect collectors
5. **Flexibility**: Easy to add new enrichment services or modify submission behavior
6. **Progressive Enhancement**: Metadata is built up incrementally, making it easy to add new enrichment types

## Configuration

**Settings are configured in Haven.app and persisted as plist files.**

Each collector can independently configure:
- Whether to skip enrichment (contacts always skip)
- Which enrichment steps to enable (OCR, face detection, NER, captioning)

Enrichment service parameters (timeouts, confidence thresholds, etc.) are configured globally in `hostagent.yaml` via `ModulesConfig`.

The Submitter service has no batch size configuration - it accepts whatever batches collectors pass in. Collectors control their own batching behavior.

**Example plist structure (conceptual):**
```xml
<!-- Haven.app plist configuration -->
<dict>
    <key>collectors</key>
    <dict>
        <key>email</key>
        <dict>
            <key>skipEnrichment</key>
            <false/>
        </dict>
        <key>contacts</key>
        <dict>
            <key>skipEnrichment</key>
            <true/>
        </dict>
    </dict>
</dict>
```

**Note**: 
- Enrichment service configuration (OCR, Face, Entity, Caption) comes from the existing `hostagent.yaml` config file via `ModulesConfig`
- Collection module configuration (TextExtractor, ImageExtractor) may also be in config or hardcoded
- The plist only controls per-collector behavior like `skipEnrichment`
- The orchestrator reads from `HavenConfig.modules.*` to initialize enrichment services
- Collectors use shared `TextExtractor` and `ImageExtractor` modules during collection (before enrichment)

## Open Questions

1. Should enrichment be synchronous (blocking) or asynchronous (fire-and-forget)?
    - Enrichment is synchronous by design to ensure the document is fully enriched before submission.
2. How should we handle enrichment failures? Should documents be submitted without enrichment?
    - Enrichment failures should be logged and the document should be submitted without enrichment.
3. Should we support partial enrichment (e.g., OCR succeeds but face detection fails)?
    - Yes, and log the failure on the document.
4. How should we handle very large batches? Should there be a maximum batch size?
    - No maximum batch size. The Submitter accepts whatever batches collectors pass in. Batch size is controlled by collectors.
5. Should enrichment be configurable per collector or globally?
    - Per-collector. Each collector may enable/disable enrichment steps individually. Settings are configured in Haven.app and persisted as plist. Skipping enrichment is decided at the collector level, not the enrichment service level.

## Next Steps

1. Review and approve this design proposal
2. Create implementation tasks in beads
3. Begin Phase 1 implementation (extract submission logic)
4. Iterate based on feedback and testing


