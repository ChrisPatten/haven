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
  - `content: String` - Markdown text extracted from source with `{IMG:<id>}` tokens inserted where images appear
  - `sourceType: String` - document origin ("imessage", "email", "localfs", etc.)
  - `externalId: String` - unique ID within source (e.g. "imessage:1234567890")
  - `metadata: DocumentMetadata` - content hash, MIME type, timestamps (created/modified), additional metadata dict
  - `images: [ImageAttachment]` - extracted images with temporary data or path refs (files NOT retained, only metadata). Collectors insert `{IMG:<id>}` tokens in content where images appear, using deterministic IDs (MD5 for embedded images, file paths for files).
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
- **Queue Population**: Collectors fill the queue by calling `queueForEnrichment()` for each document as they traverse data sources
- Configurable concurrency via `maxConcurrentEnrichments` (default: 1) - determines number of enrichment workers
- All documents are queued for enrichment
- Queue maintains: `enrichmentTasks` (document ID → Task), `activeEnrichmentCount`, `waitingQueue` (FIFO buffer when at capacity)

### Queue Operations:
- `queueForEnrichment(document, documentId, onComplete)` - called by collectors to enqueue documents for enrichment
  - Returns `true` if queued successfully, `false` if already queued
  - All documents go through enrichment; image-related steps (OCR, face detection, captioning) are skipped if document has no images
  - NER runs on all documents (if enabled), regardless of image presence
  - NER runs after all other enrichment steps are complete and includes OCR text if available.
  - Callback `onComplete: (String, EnrichedDocument?) -> Void` invoked when enrichment completes
- `waitForEnrichment(documentId)` - synchronous wait for enrichment completion
- `cancelEnrichment(documentId)` / `cancelAll()` - cleanup

### Enrichment Worker Model:
- **Worker Creation**: A configurable number of enrichment workers are created when the first collector starts (controlled by `maxConcurrentEnrichments`)
- **Worker Lifecycle**: Workers persist across all collectors and are destroyed when the last collector completes (multiple collectors may run simultaneously, all posting documents to the same queue)
- **Document Claiming**: Workers claim documents from the queue (FIFO order), marking them as active
- **Enrichment Pipeline**: Each worker executes the enrichment orchestrator pipeline asynchronously on the claimed document
- **Submission**: On success, worker asynchronously posts the enriched document to the document submitter for collection into batches (worker does not block; continues processing next document immediately)
- **Error Handling**:
  - On retryable error: increment retry count in metadata, re-queue (configurable max retries)
  - On non-retryable error: send to error log/output (logging system)

### Key Implementation Detail:
- `EnrichmentQueue` uses async Task-based concurrency control with `AsyncSemaphore` to limit parallel enrichments
- Workers operate independently, claiming and processing documents concurrently up to the configured limit
- Completion callbacks allow handlers to track enriched documents without blocking the queue
- Collector tracks incremental progress as documents are enriched and published; collector is not terminated until all documents have been submitted

---

## 3. Enrichment Pipelines

### Pipeline Architecture:
- `DocumentEnrichmentOrchestrator` actor coordinates sequential enrichment steps
- Services instantiated based on config: `OCRService?`, `FaceService?`, `EntityService?`, `CaptionService?`
- Each service is optional; pipeline is determined by what services exist + config flags

### Sequential Enrichment Steps:
1. **OCR** (if enabled & OCRService exists & document has images) - processes each image attachment
   - Skipped if document has no images
   - Returns `OCRResult` with `ocrText`, `recognitionLevel`, `lang`
2. **Face Detection** (if enabled & FaceService exists & document has images) - processes each image
   - Skipped if document has no images
   - Returns `FaceDetectionResult` with face count, bounding boxes, confidence scores, landmarks
3. **Captioning** (if enabled & CaptionService exists & document has images) - generates description per image
   - Skipped if document has no images
   - Takes image url or base64 encoded image data as context
   - Returns `String` caption (NOT further enriched; no NER applied to captions)
   - Settings control which type of captioner is used (Ollama, OpenAI, etc.). Different captioners handle images in different ways, per the requirements of the captioning service.
4. **NER** (if enabled & EntityService exists) - extracts entities from ALL documents:
   - Always runs on every document (if enabled), regardless of image presence
   - Extracts entities from document primary text (`document.content`)
   - If images exist: also extracts from all OCR results combined (across all images)
   - Caption text is NOT included in NER
   - Returns `[Entity]` with type, text, confidence, range metadata

### Result Structure:
- Returns `EnrichedDocument` containing:
  - `base: CollectorDocument` - original document
  - `documentEnrichment: DocumentEnrichment?` - entities extracted from text
  - `imageEnrichments: [ImageEnrichment]` - parallel array to `base.images`, one enrichment per image

---

## 4. Token → Slug Pipeline

### Image Token → Slug Strategy:
- **Collection Phase**: Collectors insert `{IMG:<id>}` tokens in document content where images appear
  - ID format: MD5 hash (lowercase hex) for embedded images, canonical file path for file-based images
  - Tokens preserve positional context and ensure exactly one placeholder per image
- **Enrichment Phase**: `EnrichmentMerger` replaces tokens with image slugs after enrichment completes
- **Slug Format**: `[Image: <caption> | <filename or hash>]`
  - Caption: Image caption text, or `"No caption"` if captioning failed
  - Filename/Hash: Image filename for files, MD5 hash for embedded images
- **Result**: Exactly one slug per image, positioned correctly in text, no duplicate placeholders

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
- `submitBatch([EnrichedDocument])` - converts to `EmailDocumentPayload` format (to be renamed to `DocumentPayload`) + submits
- Converts enriched documents to gateway payload via `convertToEmailDocumentPayload()`
- Handles batch size negotiation: tries batch endpoint; falls back to individual submissions if unavailable

### Batch Submission Flow:
1. Collect documents until batch size reached (default: 200, configurable in gateway settings) OR queue is empty and all enrichment pipelines are complete (no timeout; submit final batch when processing is done)
2. Convert each `EnrichedDocument` → `EmailDocumentPayload` (Swift payload type that represents the gateway API format; to be renamed to `DocumentPayload`)
3. Serialize `EmailDocumentPayload` to JSON and call `gatewayClient.submitDocumentsBatch(payloads)` (tries `/v1/ingest:batch` endpoint)
4. On success: return `SubmissionResult.success(submission: GatewaySubmissionResponse)`
5. On failure: parse error, determine if retryable (HTTP 5xx → retryable), return `SubmissionResult.failure(error, statusCode, retryable)`
6. Update CollectorStats (per-instance, updated in real-time) with submission results (number of documents submitted, number of documents failed, number of documents retried). CollectorStats drives progress information shown to users (progress bar, count, or percentage).

### Gateway Payload Structure (`EmailDocumentPayload`):
- `EmailDocumentPayload` is the Swift representation of the payload submitted to the gateway service
- **Note**: The following types should be renamed to reflect their generic use across all document types (not just email):
  - `EmailDocumentPayload` → `DocumentPayload`
  - `EmailDocumentContent` → `DocumentContent`
  - `EmailDocumentMetadata` → `DocumentMetadata`
- When serialized to JSON, it matches the gateway API's `IngestRequestModel` format
- Key fields: `sourceType`, `externalId`, `title` - document identity (`externalId` is transmitted to the gateway as `source_id` for backwards compatibility)
- `content: EmailDocumentContent` (to be renamed to `DocumentContent`) - text with MIME type (includes image placeholders)
- `metadata: EmailDocumentMetadata` (to be renamed to `DocumentMetadata`) - enrichment entities, image captions, additional metadata
- Idempotency key: SHA256(`sourceType:externalId:textHash`) sent in the `Idempotency-Key` header

---

## 6. Replies/Reactions Handling

### Reaction Detection (iMessage Example):
- In iMessage DB: `associated_message_type` field (2000-2005 = reactions/tapbacks, 1000 = sticker)
- Mapping: 2000→❤️, 2001→😂, 2002→😮, 2003→😢, 2004→😡, 2005→👍

### Reaction Document Creation:
- Reactions: document's `content` field contains the reaction emoji (e.g., "👍", "❤️", "😂")
- Replies: document's `content` field contains the reply text
- Catalog service handles formatting as "Reacted <emoji> to: <target message>" or "Replied <text> to: <target message>" in post-processing phase

### Reply Document Creation:
- `documents.metadata.in_reply_to` metadata field captures parent message reference
- Parent message GUID stored as `in_reply_to.reply_to_message_external_id` for later resolution
- `in_reply_to.reply_unprocessed: true` flag set on document creation

### Catalog Post-Processing (After Batch Ingestion):
- After gateway accepts document batch, catalog processes ingested documents in background job
- **Catalog Resolution Job:**
  1. Query documents WHERE `metadata->'in_reply_to'->>'reply_unprocessed' = 'true'`
  2. For each, extract `reply_to_message_external_id` from `metadata.in_reply_to.reply_to_message_external_id`
  3. Look up referenced document by external ID in catalog
  4. If found: update `parent_doc_id` field in documents table
  5. Remove `reply_unprocessed` key from `metadata.in_reply_to` JSONB object
  6. Mark resolution as complete

### Data Model:
- `documents.parent_doc_id UUID` - foreign key to parent document
- `documents.metadata JSONB` contains: `{"in_reply_to": {"reply_to_message_external_id": "imessage:...", "reply_unprocessed": true}}`
- After resolution: `reply_unprocessed` key deleted, `parent_doc_id` populated

---

## 7. Error Handling & Retry Strategy

### Enrichment Errors:
- Tracked in `EnrichedDocument` with optional error details
- Retryable errors (network, timeout): re-queued with incremented `retryAttempts` counter
- Non-retryable errors (validation, data corruption): logged to error output; not re-queued
- Configurable max retries (default: 3) before sending to error log

### Submission Errors:
- Gateway returns: `statusCode`, `errorMessage`, `retryable: Bool`
- HTTP 5xx errors marked as retryable; 4xx usually not
- **Batch Retry Behavior**:
  - If batch fails with `retryable=true`: entire batch is retried (up to configured max retries, default: 3). Assumes transport error that prevented batch processing.
  - If batch fails with `retryable=false`: attempt to identify partial success. If gateway provides per-document results:
    - Log errors for failed documents
    - Submit remaining documents individually (those that succeeded in batch or weren't processed)
  - If partial success cannot be determined: submit all documents individually, log errors for failing documents (not retried)


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
- Concurrency limits for enrichment workers (`maxConcurrentEnrichments`)
- Retry limits for failed enrichments (default: 3)
- Batch size for document submission (default: 200, configurable in gateway settings under `settings->general`)

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
4. Image data never submitted to gateway; only metadata transmitted
5. Batch submitter handles idempotency and error recovery
6. Replies/reactions resolved asynchronously in catalog post-processing phase
