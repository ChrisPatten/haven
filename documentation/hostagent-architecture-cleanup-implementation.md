# HostAgent Architecture Cleanup - Implementation Status

## Overview

This document tracks the implementation progress of the HostAgent Architecture Cleanup design proposal.

## Completed Components

### 1. Document Type Structures ✅
- **Location**: `hostagent/Sources/HavenCore/DocumentTypes.swift`
- **Components**:
  - `CollectorDocument` - Base document structure from collectors
  - `EnrichedDocument` - Document with enrichment data
  - `ImageAttachment` - Image metadata (files not retained)
  - `DocumentEnrichment` - Primary document enrichment (entities)
  - `ImageEnrichment` - Per-image enrichment (OCR, faces, captions)
  - `SubmissionResult` - Submission result structure

### 2. Shared Collection Modules ✅
- **TextExtractor**: `hostagent/Sources/HavenCore/TextExtractor.swift`
  - Generalized from `EmailBodyExtractor`
  - Converts HTML/rich text to markdown
  - Strips quoted content and signatures
  - Used by all collectors during collection

- **ImageExtractor**: `hostagent/Sources/HavenCore/ImageExtractor.swift`
  - Generalized from `EmailImageExtractor`
  - Extracts images from HTML and file content
  - Returns image metadata (hash, mime type, dimensions)
  - Files are NOT retained, only metadata

### 3. Enrichment Services ✅
- **CaptionService**: `hostagent/Sources/Caption/CaptionService.swift`
  - Placeholder implementation
  - Ready for Ollama/Vision integration
  - Added to `Package.swift` as new module

- **CaptionModuleConfig**: Added to `hostagent/Sources/HavenCore/Config.swift`
  - Configuration for caption service
  - Integrated into `ModulesConfig`

### 4. Enrichment Orchestrator ✅
- **Location**: `hostagent/Sources/HavenCore/EnrichmentOrchestrator.swift`
- **Components**:
  - `EnrichmentOrchestrator` protocol
  - `DocumentEnrichmentOrchestrator` implementation
  - Coordinates OCR, Face Detection, NER, and Captioning
  - Handles per-image enrichment independently
  - Includes OCR text in NER processing (but not captions)

### 5. Document Submitter ✅
- **Location**: `hostagent/Sources/HostAgent/Submission/DocumentSubmitter.swift`
- **Components**:
  - `DocumentSubmitter` protocol
  - `BatchDocumentSubmitter` implementation
  - Handles batching and retry logic
  - Converts `EnrichedDocument` to `EmailDocumentPayload` for submission
  - Accepts batches of any size from collectors

### 6. Package Configuration ✅
- Updated `hostagent/Package.swift`:
  - Added `Caption` module
  - Added `Face` module to products
  - Updated `HavenCore` dependencies (SwiftSoup, Demark, HTMLEntities)
  - Updated `HostAgentEmail` dependencies (OCR, Entity, Face, Caption)

## Remaining Work

### Phase 3: Collector Refactoring (In Progress)

The collectors need to be refactored to use the new architecture:

1. **EmailCollector** (`hostagent/Sources/HostAgent/Collectors/EmailCollector.swift`)
   - Add methods using new architecture:
     - `collectAndSubmit(email:)` - Uses TextExtractor, ImageExtractor, EnrichmentOrchestrator, DocumentSubmitter
   - Keep existing methods for backward compatibility during migration
   - Update initialization to accept EnrichmentOrchestrator and DocumentSubmitter

2. **LocalFSCollector** (`hostagent/Sources/HostAgent/Collectors/LocalFSCollector.swift`)
   - Similar refactoring pattern
   - Use TextExtractor and ImageExtractor
   - Pass through enrichment and submission

3. **IMessageHandler** (`hostagent/Sources/CollectorHandlers/Handlers/IMessageHandler.swift`)
   - Refactor to use new architecture
   - Handle iMessage-specific metadata

4. **ContactsHandler** (`hostagent/Sources/CollectorHandlers/Handlers/ContactsHandler.swift`)
   - Skip enrichment (as per design)
   - Use DocumentSubmitter directly

## Architecture Flow

```
Collector
  │
  ├─> TextExtractor (extract text from HTML/rich text)
  ├─> ImageExtractor (extract image metadata)
  │
  └─> Build CollectorDocument
      │
      ├─> EnrichmentOrchestrator (if not skipped)
      │   ├─> OCR on images
      │   ├─> Face Detection on images
      │   ├─> Captioning on images
      │   └─> NER on text + OCR text
      │
      └─> DocumentSubmitter
          └─> Gateway API
```

## Key Design Decisions

1. **Image Storage**: Images are NOT retained - only metadata (hash, mime type, dimensions) and enrichment results are kept. Images are loaded temporarily during enrichment, then discarded.

2. **Caption Handling**: Captions are NOT enriched further (no NER on captions) - they are final enrichment data.

3. **Enrichment Failures**: Partial enrichment is supported - if OCR fails but face detection succeeds, the document is still submitted with available enrichment data.

4. **Backward Compatibility**: Existing collector methods are preserved during migration to allow gradual transition.

5. **Configuration**: Enrichment settings come from `ModulesConfig` in `HavenConfig`. Per-collector skip enrichment settings would come from Haven.app plist (not yet implemented).

## Next Steps

1. Refactor EmailCollector to add new architecture methods
2. Update collector initialization to accept enrichment/submitter services
3. Refactor other collectors (LocalFS, IMessage, Contacts)
4. Update collector handlers to use new architecture
5. Add per-collector configuration support (skipEnrichment flag)
6. Testing and validation
7. Remove legacy code after migration is complete

## Notes

- The conversion from `EnrichedDocument` to `EmailDocumentPayload` in `DocumentSubmitter` is a temporary solution. In the future, we may want a more generic payload format that supports all document types.

- The `CaptionService` is currently a placeholder. Actual implementation would integrate with Ollama or Vision framework.

- Image data is temporarily stored in `ImageAttachment.temporaryData` or `temporaryPath` for enrichment, then discarded. The actual storage strategy may need refinement based on use cases.

