# Intents Capability: Implementation Remaining

This document outlines what remains to be implemented to enable the LLM-based Intents capability as designed in `intents-design-proposal.md`.

## Current State Assessment

### ✅ What Exists

1. **Client-Side NER Preprocessing (Haven.app)**
   - ✅ Complete - Entity extraction using native macOS frameworks
   - ✅ Collectors integrated - Entities included in payloads sent to Gateway
   - ✅ Entity serialization - Entities flow from Haven.app → Gateway → Catalog

2. **Worker Pattern Reference**
   - `services/worker_service/base.py` - Base worker framework for queue-based worker pattern
   - `services/worker_service/workers/embedding.py` - Embedding worker implementation
   - Uses `FOR UPDATE SKIP LOCKED` for atomic job claiming
   - Polling loop with configurable batch size and interval

3. **Database Schema**
   - `documents` table has `intent` JSONB column (legacy, for email classification)
   - No `intent_status` column yet
   - No `intent_signals` table yet

4. **Infrastructure**
   - Gateway API, Catalog API exist
   - Database connection patterns established
   - Logging and error handling patterns in place

### ❌ What's Missing

## Implementation Checklist

### Phase 1: Database Schema & Foundation

#### 1.1 Database Schema Migration
**Priority: Critical**  
**Location: `schema/migrations/`**

- [ ] Create migration to add `intent_status` column to `documents` table
  - Status values: `pending`, `processing`, `processed`, `failed`, `skipped`
  - Add `intent_processing_started_at`, `intent_processing_completed_at`, `intent_processing_error` columns
  - Add constraint for valid status values
  - Add index: `idx_documents_intent_status` on `(intent_status, created_at)` WHERE `intent_status = 'pending'`

- [ ] Create `intent_signals` table
  - Columns: `signal_id`, `artifact_id`, `taxonomy_version`, `parent_thread_id`
  - JSONB `signal_data` column
  - Status tracking: `pending`, `confirmed`, `edited`, `rejected`, `snoozed`
  - User feedback JSONB column
  - Conflict handling columns
  - Timestamps and indexes (see design doc section 2.3.2)

- [ ] Create `entity_cache` table
  - TTL-based caching for entity extraction results
  - Indexes for expiration and artifact lookup

- [ ] Create `intent_taxonomies` table
  - Versioned taxonomy storage
  - JSONB for taxonomy definitions

- [ ] Create `intent_user_preferences` table
  - User-specific automation levels and thresholds

- [ ] Create `intent_deduplication` table
  - Thread-aware deduplication tracking
  - TTL-based cleanup

#### 1.2 Catalog API Updates
**Priority: Critical**  
**Location: `services/catalog_api/app.py`**

- [ ] Update document persistence to set `intent_status = 'pending'` by default
  - Modify `/v1/catalog/documents` endpoint
  - Ensure automatic queueing when documents are created

- [ ] Add intent signal persistence endpoint
  - `POST /v1/catalog/intent-signals` - Persist signals from worker
  - `GET /v1/catalog/intent-signals/{signal_id}` - Retrieve signal
  - `PATCH /v1/catalog/intent-signals/{signal_id}/feedback` - Update feedback
  - `GET /v1/catalog/documents/{doc_id}/intent-status` - Check processing status

- [ ] Add models for intent signals
  - `IntentSignal`, `IntentResult`, `Evidence`, `ProcessingTimestamps`, `Provenance`
  - Update `shared/models_v2.py` or create `services/catalog_api/models_intents.py`

### Phase 2: Server-Side Intents Service

#### 2.1 Intents Worker Service
**Priority: Critical**  
**Location: `services/worker_service/workers/intents.py`** (part of unified worker service)

- [x] Create worker service structure
  - ✅ Refactored `services/embedding_service` → `services/worker_service` with base worker framework
  - ✅ Intents worker skeleton created in `services/worker_service/workers/intents.py`
  - ✅ Poll database for `intent_status = 'pending'` documents
  - ✅ Use `FOR UPDATE SKIP LOCKED` for atomic job claiming

- [x] Implement job dequeue logic
  - ✅ Query documents with `intent_status = 'pending'`
  - ✅ Atomically claim jobs and set status to `processing`
  - ✅ Batch processing (configurable, default 8)

- [ ] Implement intent classification
  - Load taxonomy from database or files
  - Classify artifacts using LLM (Ollama/local) or rules
  - Multi-label intent detection
  - Compute confidence scores
  - Apply channel-aware priors

- [ ] Implement slot filling
  - Map pre-processed entities to intent slots
  - Extract missing slots from text using LLM
  - Validate slot constraints (types, enums, ranges)
  - Mark missing required slots

- [ ] Implement evidence generation
  - Generate text spans for evidence
  - Link entity references
  - Include layout references for OCR documents

- [ ] Implement deduplication
  - Check against `intent_deduplication` table
  - Suppress duplicate signals within window
  - Thread-aware deduplication

- [ ] Implement thread-aware merging
  - Merge complementary slots from thread context
  - Detect conflicts between signals

- [ ] Implement signal validation
  - Schema validation against taxonomy
  - Ensure evidence completeness
  - Generate stable signal IDs

- [ ] Implement signal persistence
  - Persist signals to `intent_signals` table via Catalog API
  - Update document `intent_status` to `processed`
  - Handle errors and mark as `failed` with error details

- [ ] Add configuration
  - `WORKER_POLL_INTERVAL` (default: 2.0 seconds)
  - `WORKER_BATCH_SIZE` (default: 8)
  - `INTENT_REQUEST_TIMEOUT` (default: 15.0 seconds)
  - Taxonomy file paths
  - Confidence thresholds

#### 2.2 Intent Classifier Module
**Priority: High**  
**Location: `src/haven/intents/classifier/`** (new package)

- [ ] Create classifier package structure
  - `__init__.py`
  - `taxonomy.py` - Load and validate taxonomy
  - `classifier.py` - Intent classification logic
  - `priors.py` - Channel-aware priors

- [ ] Implement taxonomy loader
  - Load from JSON/YAML files or database
  - Validate taxonomy schema
  - Support versioning

- [ ] Implement intent classifier
  - LLM-based classification (using Ollama/local models)
  - Rule-based fallback
  - Multi-label detection
  - Confidence scoring

- [ ] Implement channel priors
  - Apply source-specific priors (email vs iMessage vs notes)
  - Adjust confidence based on channel metadata

#### 2.3 Slot Filler Module
**Priority: High**  
**Location: `src/haven/intents/slots/`** (new package)

- [ ] Create slot filler package
  - `__init__.py`
  - `filler.py` - Main slot filling logic
  - `extractor.py` - Text extraction for missing slots
  - `validator.py` - Slot constraint validation

- [ ] Implement entity-to-slot mapping
  - Map pre-processed entities to intent slots
  - Handle type conversions (date strings to datetime, etc.)

- [ ] Implement text extraction
  - Extract slot values from free text when entities unavailable
  - Use LLM for complex extractions

- [ ] Implement slot validation
  - Validate types, enums, ranges
  - Check required vs optional slots
  - Mark missing required slots

- [ ] Implement evidence generation
  - Link slot values to text spans
  - Reference entities used for slots

#### 2.4 Signal Validator Module
**Priority: High**  
**Location: `src/haven/intents/validation/`** (new package)

- [ ] Create validator package
  - `__init__.py`
  - `validator.py` - Schema validation
  - `signal_builder.py` - Signal construction

- [ ] Implement schema validation
  - Validate against Intent Signal schema
  - Check required fields
  - Validate evidence completeness

- [ ] Implement signal construction
  - Build `IntentSignal` objects
  - Generate stable signal IDs
  - Enforce deterministic field ordering

#### 2.5 Intents API Service
**Priority: Medium**  
**Location: `services/intents_service/api.py`** (new service)

- [ ] Create FastAPI service
  - Lightweight service for querying signals (separate from worker)
  - Endpoints:
    - `GET /v1/intents/signals/{signal_id}` - Retrieve signal
    - `GET /v1/intents/signals` - Query signals (filters: artifact_id, thread_id, intent_name, status, date range)
    - `POST /v1/intents/feedback` - Record user feedback
    - `GET /v1/intents/taxonomy` - Retrieve current taxonomy version
    - `GET /v1/intents/stats` - Telemetry and metrics

- [ ] Implement signal querying
  - Query `intent_signals` table with filters
  - Join with documents for full context

- [ ] Implement feedback handling
  - Store user confirmations/corrections/rejections
  - Update signal status

- [ ] Implement telemetry
  - Aggregate metrics (coverage, quality, performance)
  - Error tracking

### Phase 3: Gateway Integration

#### 3.1 Gateway Endpoints
**Priority: Medium**  
**Location: `services/gateway_api/app.py`**

- [ ] Add intent query endpoints
  - `GET /v1/intents/signals` - Query signals (forward to Intents API)
  - `GET /v1/intents/signals/{signal_id}` - Retrieve signal
  - `POST /v1/intents/feedback` - Submit feedback
  - `GET /v1/intents/status/{doc_id}` - Check processing status

- [ ] Update artifact ingestion
  - Accept `entities` field in document payloads
  - Forward entities to Catalog API
  - Ensure automatic queueing (handled by Catalog)

#### 3.2 Gateway Routes Module
**Priority: Low**  
**Location: `services/gateway_api/routes/intents.py`** (new file)

- [ ] Create dedicated routes module for intents
  - Keep gateway app.py clean
  - Forward requests to Intents API service

### Phase 4: Taxonomy & Configuration

#### 4.1 Taxonomy Definitions
**Priority: High**  
**Location: `services/intents_service/taxonomies/`** (new directory)

- [ ] Create initial taxonomy files
  - `taxonomy_v1.0.0.yaml` - MVP intents (task.create, schedule.create, reminder.create)
  - Define slots for each intent
  - Set constraints and validation rules

- [ ] Implement taxonomy loader
  - Load from YAML/JSON files
  - Validate schema
  - Store in database for versioning

#### 4.2 Configuration Management
**Priority: Medium**  
**Location: `services/intents_service/config.yaml`** (new file)

- [ ] Create service configuration
  - Processing timeouts
  - Confidence thresholds per intent
  - Deduplication windows
  - Entity cache TTL
  - Privacy settings

### Phase 5: Testing & Documentation

#### 5.1 Unit Tests
**Priority: Medium**

- [ ] Test intent classifier (Python)
  - Taxonomy loading
  - Intent detection
  - Confidence scoring

- [ ] Test slot filler (Python)
  - Entity mapping
  - Text extraction
  - Validation

- [ ] Test signal validator (Python)
  - Schema validation
  - Signal construction

- [ ] Test worker (Python)
  - Job dequeue
  - Processing pipeline
  - Error handling

#### 5.2 Integration Tests
**Priority: Medium**

- [ ] End-to-end test: Collector → Gateway → Catalog → Worker → Signal
- [ ] Test entity flow: Haven.app → Gateway → Catalog → Worker
- [ ] Test deduplication across threads
- [ ] Test error handling and retries

#### 5.3 Documentation Updates
**Priority: Low**

- [ ] Update architecture docs
- [ ] Add API documentation for intents endpoints
- [ ] Create user guide for intent signals
- [ ] Document taxonomy management

## Implementation Order (Recommended)

1. **Database Schema** (Phase 1.1) - Foundation for everything
2. **Catalog API Updates** (Phase 1.2) - Enable automatic queueing
3. **Intents Worker** (Phase 2.1) - Core processing logic
4. **Classifier/Slot Filler/Validator** (Phases 2.2-2.4) - Processing modules
5. **Intents API** (Phase 2.5) - Query interface
6. **Gateway Integration** (Phase 3) - Public API
7. **Taxonomy & Config** (Phase 4) - Content and settings
8. **Testing & Docs** (Phase 5) - Quality and usability

**Note:** Client-side NER preprocessing is already complete - entities flow from Haven.app → Gateway → Catalog automatically.

## Key Dependencies

- **Worker Pattern**: Use `services/worker_service/base.py` and `services/worker_service/workers/embedding.py` as reference
- **Client-Side NER**: Already complete - entities are extracted in Haven.app and included in payloads
- **Database Patterns**: Follow existing Catalog API patterns for persistence
- **LLM Integration**: Use Ollama/local models (similar to embedding service)

## Open Questions to Resolve

1. **Model Selection**: 
   - Intent classification: Prompt-based LLM vs fine-tuned model?
   - Slot filling: Rule-based vs LLM-based?
   - **Recommendation**: Start with prompt-based LLM (Ollama) for flexibility

2. **Taxonomy MVP**: 
   - Which 8 intents are MVP-critical?
   - Default confidence thresholds?
   - **Recommendation**: task.create, schedule.create, reminder.create as MVP

3. **Deduplication Window**: 
   - 24-hour window as proposed?
   - Cross-channel deduplication strategy?

4. **User Preferences**: 
   - Snapshot at signal time vs lookup at action time?
   - **Recommendation**: Snapshot for auditability

## Notes

- The design follows the same queue-based pattern as the embedding worker, which is proven and scalable
- ✅ **Client-side NER is complete** - Entities are extracted in Haven.app using native macOS frameworks and flow through Gateway to Catalog
- The architecture supports horizontal scaling of workers
- All processing defaults to local-first with remote opt-in

