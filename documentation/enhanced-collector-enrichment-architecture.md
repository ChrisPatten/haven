# Enhanced Haven Collector & Enrichment Architecture Requirements

## 1. Collector Instance & Document Creation

### Collector Spawning with Settings:
- A collector instance is spawned with configuration (from `HavenConfig` and collector-specific settings like `IMessageCollectorConfig`)
- Settings determine: enrichment enabled/disabled, enrichment pipeline variant (e.g., Ollama vs OpenAI captioner), skip flags, module-specific configs (OCR, Face, Entity, Caption)
- The collector maintains state: `isRunning`, `lastRunTime`, `lastRunStatus`, `lastRunStats`, `lastRunError`

### Initial Summary Query:
- Before processing, collectors perform a COUNT query on the data source (e.g., iMessage DB with SQLite) filtered by scope parameters (`since`, `until`, message lookback days, fences)
- This count is captured in `CollectorStats` struct: `documentsToCreate`, `messagesProcessed`, `threadsProcessed`, `attachmentsProcessed`
- Fences track already-processed ranges to avoid reprocessing (timestamp pairs with ISO8601 format)

### Document Instance Creation (Standardized Format):
- Each document is created as a `CollectorDocument` struct with standardized fields:
  - `content: String` - Markdown text extracted from source (enriched with image placeholders)
  - `sourceType: String` - document origin ("imessage", "email", "localfs", etc.)
  - `sourceId: String` - unique ID within source
  - `metadata: DocumentMetadata` - content hash, MIME type, timestamps (created/modified), additional metadata dict
  - `images: [ImageAttachment]` - extracted images with temporary data or path refs (files NOT retained, only metadata)
  - `contentType: DocumentContentType` - enum-based type
  - `title: String?`, `canonicalUri: String?` - optional fields

### Document Instance Lifecycle:
- Document instances are created as collectors traverse data sources (one doc per message/email/file)
- For iMessage: 1 document per message (reactions/tapbacks are converted to readable text)
- For Email: 1 document per email message; attachments handled separately via `submitEmailAttachment` flow
- For LocalFS: 1 document per file
- Each document includes `ImageAttachment` array with filename, size, hash, and optional temporary data/path refs

---

## 2. FIFO Enrichment Queue & Processing

### Queue Architecture:
- `EnrichmentQueue` actor manages concurrent enrichment of documents with attachments
- Configurable concurrency via `maxConcurrentEnrichments` (default: 1)
- Only documents with images are queued; others proceed directly to enrichment orchestrator or submission
- Queue maintains: `enrichmentTasks` (document ID → Task), `activeEnrichmentCount`, `waitingQueue` (FIFO buffer when at capacity)

### Queue Operations:
- `queueForEnrichment(document, documentId, onComplete)` - enqueues if document has images and not already queued
  - Returns `true` if queued successfully, `false` if no images or already queued
  - Callback `onComplete: (String, EnrichedDocument?) -> Void` invoked when enrichment completes
- `waitForEnrichment(documentId)` - synchronous wait for enrichment completion
- `cancelEnrichment(documentId)` / `cancelAll()` - cleanup

### Enrichment Worker Model:
- Pulled from queue by consumers (currently in Haven.app: 1+ controller workers per collector run)
- Workers execute the enrichment orchestrator pipeline asynchronously
- On success: pass enriched document to document submitter
- On retryable error: increment retry count in metadata, re-queue (configurable max retries)
- On non-retryable error: send to error log/output (logging system)

### Key Implementation Detail:
- `EnrichmentQueue` uses async Task-based concurrency control with `AsyncSemaphore` to limit parallel enrichments
- Completion callbacks allow handlers to track enriched documents without blocking the queue

---

## 3. Enrichment Pipelines

### Pipeline Architecture:
- `DocumentEnrichmentOrchestrator` actor coordinates sequential enrichment steps
- Services instantiated based on config: `OCRService?`, `FaceService?`, `EntityService?`, `CaptionService?`
- Each service is optional; pipeline is determined by what services exist + config flags

### Sequential Enrichment Steps:
1. **OCR** (if enabled & OCRService exists) - processes each image attachment
   - Returns `OCRResult` with `ocrText`, `recognitionLevel`, `lang`
2. **Face Detection** (if enabled & FaceService exists) - processes each image
   - Returns `FaceDetectionResult` with face count, bounding boxes, confidence scores, landmarks
3. **Captioning** (if enabled & CaptionService exists) - generates description per image
   - Takes image data + optional OCR text as context
   - Returns `String` caption (NOT further enriched; no NER applied to captions)
4. **NER** (if enabled & EntityService exists) - extracts entities from:
   - Document primary text (`document.content`)
   - All OCR results combined (across all images)
   - Caption text is NOT included in NER
   - Returns `[Entity]` with type, text, confidence, range metadata

### Image Processing:
- Images processed in parallel using `TaskGroup` with configurable concurrency (clamped 1-16)
- Image data loaded temporarily (from `temporaryData` or `temporaryPath` fields)
- Image data is NOT retained after enrichment (memory efficiency)
- Each image enrichment stored as `ImageEnrichment` struct with optional `ocr`, `faces`, `caption` fields

### Result Structure:
- Returns `EnrichedDocument` containing:
  - `base: CollectorDocument` - original document
  - `documentEnrichment: DocumentEnrichment?` - entities extracted from text
  - `imageEnrichments: [ImageEnrichment]` - parallel array to `base.images`, one enrichment per image

---

## 4. Message Formatting & Image Placeholder Embedding

### Image Placeholder Format:
- `[Image: <filename> | <caption> | <ocr_text>]` - inline text representation
- Applied to document text via `EnrichmentMerger.mergeEnrichmentIntoDocument()`

### Enrichment Metadata Structure:
- Merged into `metadata.enrichment` JSONB field:
  ```json
  {
    "entities": [
      {"type": "person", "text": "Alice", "confidence": 0.95, "range": [0, 5]},
      ...
    ],
    "captions": ["Person smiling", ...],
    "images": [
      {
        "filename": "photo.jpg",
        "caption": "Person smiling",
        "ocr": {
          "text": "OCR extracted text",
          "recognition_level": "accurate",
          "lang": ["en"]
        },
        "faces": {
          "count": 1,
          "detections": [
            {
              "confidence": 0.98,
              "bounds": {"x": 10, "y": 20, "width": 100, "height": 120}
            }
          ]
        }
      }
    ]
  }
  ```

### Business Rule:
- Image files are NOT sent to gateway (binary data stays on host)
- Only metadata and text placeholders transmitted
- Image data temporarily loaded during enrichment, then released

---

## 5. Document Submission & Batching

### Batch Document Submitter:
- `BatchDocumentSubmitter` actor collects `EnrichedDocument` instances
- `submitBatch([EnrichedDocument])` - converts to `EmailDocumentPayload` format + submits
- Converts enriched documents to gateway payload via `convertToEmailDocumentPayload()`
- Handles batch size negotiation: tries batch endpoint; falls back to individual submissions if unavailable

### Batch Submission Flow:
1. Collect documents until batch size reached OR timeout
2. Convert each `EnrichedDocument` → `EmailDocumentPayload` (generic payload format)
3. Call `gatewayClient.submitDocumentsBatch(payloads)` (tries batch endpoint)
4. On success: return `SubmissionResult.success(submission: GatewaySubmissionResponse)`
5. On failure: parse error, determine if retryable (HTTP 5xx → retryable), return `SubmissionResult.failure(error, statusCode, retryable)`

### Gateway Payload Structure:
- `sourceType`, `sourceId`, `title` - document identity
- `content: EmailDocumentContent` - text with MIME type (includes image placeholders)
- `metadata: EmailDocumentMetadata` - enrichment entities, image captions, additional metadata
- Idempotency key: SHA256(`sourceType:sourceId:textHash`)

---

## 6. Replies/Reactions Handling

### Reaction Detection (iMessage Example):
- In iMessage DB: `associated_message_type` field (2000-2005 = reactions/tapbacks, 1000 = sticker)
- Mapping: 2000→❤️, 2001→😂, 2002→😮, 2003→😢, 2004→😡, 2005→👍

### Reaction Document Creation:
- Reactions converted to readable text in `buildDocument()` method
- Text format: `"Reacted 👍 to: <first 50 chars of target message>"`
- Lookup target message from DB to embed context

### Reply Document Creation:
- `in_reply_to` metadata field captures parent message reference
- Parent message GUID stored for later resolution

### Metadata for Later Resolution:
- Documents with `reply_to_message_external_id` metadata key (external IDs formatted as `imessage:<guid>`) marked as unresolved
- `reply_unprocessed: true` flag set on document creation
- These are stored in `documents.metadata` JSONB field

### Catalog Post-Processing (After Batch Ingestion):
- After gateway accepts document batch, catalog processes ingested documents in background job
- **Catalog Resolution Job:**
  1. Query documents WHERE `metadata->>'reply_unprocessed' = 'true'`
  2. For each, extract `reply_to_message_external_id` from metadata
  3. Look up referenced document by external ID in catalog
  4. If found: update `parent_doc_id` field in documents table
  5. Remove `reply_unprocessed` key from metadata JSONB
  6. Mark resolution as complete

### Data Model:
- `documents.parent_doc_id UUID` - foreign key to parent document
- `documents.metadata JSONB` contains: `{"reply_to_message_external_id": "imessage:...", "reply_unprocessed": true}`
- After resolution: `reply_unprocessed` key deleted, `parent_doc_id` populated

---

## 7. Error Handling & Retry Strategy

### Enrichment Errors:
- Tracked in `EnrichedDocument` with optional error details
- Retryable errors (network, timeout): re-queued with incremented `retryAttempts` counter
- Non-retryable errors (validation, data corruption): logged to error output; not re-queued
- Configurable max retries (e.g., `maxRetries: 3`) before sending to error log

### Submission Errors:
- Gateway returns: `statusCode`, `errorMessage`, `retryable: Bool`
- HTTP 5xx errors marked as retryable; 4xx usually not
- Batch submission failures propagate error to all documents in batch

### Logging:
- Structured logging via `HavenLogger(category: "enrichment-queue")`, etc.
- Log levels: `debug` (progress), `info` (significant events), `warning` (recoverable errors), `error` (non-recoverable)
- Metadata dict includes context: document IDs, image counts, error details, timestamps

---

## 8. Key Configuration Points

### From HavenConfig:
- `modules.ocr.enabled` - enable OCR module
- `modules.face.enabled` - enable Face detection
- `modules.entity.enabled` - enable Named Entity Recognition
- `modules.caption.enabled` - enable Image captioning (OpenAI, Ollama, etc.)
- `modules.entity.types` - list of entity types to extract
- `modules.entity.minConfidence` - confidence threshold for entities
- Concurrency limits for enrichment workers
- Retry limits for failed enrichments
- Batch size for document submission

### Per-Collector Settings:
- `messageLookbackDays` - iMessage lookback window
- Enrichment skip flags (per collector)
- Source redaction options

---

## Summary

This architecture creates a highly modular, testable pipeline where:
1. Collectors create standardized `CollectorDocument` instances
2. FIFO queue manages backpressure for enrichment
3. Enrichment pipeline is configurable per module
4. Image data never leaves host; only metadata transmitted
5. Batch submitter handles idempotency and error recovery
6. Replies/reactions resolved asynchronously in catalog post-processing phase

