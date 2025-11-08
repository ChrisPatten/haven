# LLM-Based Intents Capability: Design Proposal

## Executive Summary

This design proposes a client-server, queue-based architecture for Haven's LLM-based Intents capability:

- **Client-Side (Haven.app)**: NER preprocessing using native macOS frameworks (NaturalLanguage, Vision, Contacts, CoreLocation) extracts entities before sending artifacts to the Gateway
- **Server-Side (Intents Worker)**: Queue-based background worker (similar to embedding worker) polls database for pending documents and performs intent classification, slot filling, and signal generation

**Key Benefits:**
- **Privacy**: Entity extraction never leaves the device
- **Performance**: Native frameworks provide fast, optimized processing
- **Reliability**: Leverages proven macOS system frameworks
- **Scalability**: Queue-based architecture enables horizontal scaling and natural backpressure
- **Consistency**: Follows same pattern as embedding worker for operational familiarity
- **Integration**: Seamlessly integrates with existing Haven.app collectors

## 1. Overview

This document proposes a design for Haven's LLM-based Intents capability, which converts heterogeneous personal text artifacts (messages, emails, notes, OCR, documents) into reliable, explainable Intent Signals suitable for automation and user action.

### 1.1 Purpose

The Intents capability identifies actionable intents within artifacts, extracts structured entities via Named Entity Recognition (NER), fills intent slots, and produces validated, machine-readable signals with confidence scores and evidence. This enables downstream automation (e.g., task creation, event scheduling, reminders) while respecting privacy defaults and user control.

### 1.2 Integration with Haven Architecture

The Intents capability integrates as a new service within Haven's existing microservices architecture, with NER preprocessing performed client-side in Haven.app:

```
Haven.app (macOS)
    │
    ├─→ Collectors (iMessage, Email, Notes, Files)
    │       │
    │       └─→ NER Preprocessor (Swift, NaturalLanguage framework)
    │               ├─→ Language Detection
    │               ├─→ Entity Extraction
    │               ├─→ Text Normalization
    │               └─→ Entity Canonicalization
    │
    └─→ Gateway (:8085) [with pre-processed entities]
            │
            └─→ Catalog API (persist artifacts + entities)
                    │
                    └─→ Documents table (intent_status = 'pending')
                            │
                            └─→ Intents Worker (NEW, queue-based)
                                    │
                                    ├─→ Polls for pending documents
                                    ├─→ Intent Classifier
                                    ├─→ Slot Filler
                                    └─→ Signal Validator
                                    │
                                    └─→ Catalog API (persist signals, update intent_status)
```

**Key Integration Points:**
- **NER Preprocessing**: Performed in Haven.app using native macOS frameworks (NaturalLanguage, Vision, Contacts, etc.)
- **Input**: Artifacts with pre-processed entities flow from Haven.app → Gateway → Catalog
- **Queue**: Documents are marked with `intent_status = 'pending'` in the database
- **Processing**: Intents Worker polls database for pending documents (similar to embedding worker)
- **Output**: Intent Signals persisted in Catalog, document `intent_status` updated to 'processed'
- **Feedback**: User confirmations/corrections flow back through Gateway

### 1.3 Design Principles

1. **Local-First**: NER preprocessing occurs locally in Haven.app; all processing defaults to local; remote processing requires explicit opt-in
2. **Native-First**: Leverage macOS native frameworks (NaturalLanguage, Vision, Contacts, CoreLocation) for optimal performance and privacy
3. **Privacy-Preserving**: Minimize data exposure; redact non-evidence PII; entities extracted client-side
4. **Explainable**: Every signal includes evidence spans and entity references
5. **Schema-Driven**: Strict validation with versioned taxonomies
6. **Idempotent**: Reprocessing produces identical results (save metadata timestamps)
7. **Thread-Aware**: Leverage thread context for slot completion and deduplication

## 2. Component Architecture

### 2.1 Service Components

#### 2.1.1 Intents Worker (`services/intents_service/worker.py`)

A queue-based background worker that processes documents for intent detection (similar to embedding worker).

**Responsibilities:**
- Poll database for documents with `intent_status = 'pending'`
- Atomically claim jobs using `FOR UPDATE SKIP LOCKED`
- Perform intent classification and slot filling using provided entities
- Validate and emit Intent Signals
- Handle deduplication and thread-aware merging
- Update document `intent_status` to 'processed' or 'failed'

**Note:** NER preprocessing is performed client-side in Haven.app; this worker receives documents with pre-processed entities.

**Worker Pattern:**
- Continuous polling loop (configurable interval, default 2 seconds)
- Batch processing (configurable batch size, default 8)
- Atomic job claiming via PostgreSQL `FOR UPDATE SKIP LOCKED`
- Status tracking: `pending` → `processing` → `processed` / `failed`
- Error handling with retry logic

**Configuration:**
- `WORKER_POLL_INTERVAL` - Poll interval in seconds (default: 2.0)
- `WORKER_BATCH_SIZE` - Number of documents to process per batch (default: 8)
- `INTENT_REQUEST_TIMEOUT` - Timeout for LLM requests (default: 15.0)
- Taxonomy definitions (JSON/YAML)
- Confidence thresholds per intent
- Deduplication windows

#### 2.1.1a Intents API Service (`services/intents_service/api.py`)

A lightweight FastAPI service for querying signals and managing feedback (separate from worker).

**Responsibilities:**
- Expose signal query endpoints
- Handle user feedback (confirm/edit/reject)
- Manage taxonomy versioning
- Provide telemetry and metrics

**Endpoints:**
- `GET /v1/intents/signals/{signal_id}` - Retrieve a signal
- `GET /v1/intents/signals` - Query signals (by artifact, thread, intent, date range)
- `POST /v1/intents/feedback` - Record user feedback (confirm/edit/reject)
- `GET /v1/intents/taxonomy` - Retrieve current taxonomy version
- `GET /v1/intents/stats` - Telemetry and metrics

#### 2.1.2 NER Preprocessor Module (`Haven/Haven/Intents/NERPreprocessor.swift`)

Swift module in Haven.app that performs Named Entity Recognition preprocessing using native macOS frameworks.

**Responsibilities:**
- Language detection using `NLLanguageRecognizer`
- Text cleaning (signatures, quoted replies, boilerplate)
- Entity extraction using `NLTagger` (NaturalLanguage framework)
- OCR/document text extraction coordination (Vision framework)
- Contact matching (Contacts framework)
- Location normalization (CoreLocation framework)
- Entity canonicalization and linking
- Timezone resolution using system timezone and metadata

**Key Components:**
- `NERPreprocessor` - Main coordinator class
- `LanguageDetector` - Wraps `NLLanguageRecognizer`
- `EntityExtractor` - Extends existing `EntityService` from hostagent
- `TextNormalizer` - Handles cleaning and normalization
- `EntityCanonicalizer` - Normalizes entity values to canonical forms
- `TimezoneResolver` - Resolves timezones from text and metadata

**Native Framework Usage:**
- **NaturalLanguage**: `NLTagger` for entity extraction, `NLLanguageRecognizer` for language detection
- **Vision**: OCR text extraction (already integrated)
- **Contacts**: Contact matching and normalization
- **CoreLocation**: Location geocoding and normalization
- **Foundation**: Date parsing, timezone handling, text processing

**Key Functions:**
- `detectLanguages(_ text: String) async -> [Language]`
- `normalizeText(_ text: String, hints: ProcessingHints) -> NormalizedText`
- `extractEntities(_ text: String, layout: DocumentLayout?, metadata: ChannelMetadata) async -> EntitySet`
- `canonicalizeEntities(_ entities: [Entity], timezone: TimeZone, observedAt: Date) -> CanonicalEntitySet`
- `resolveTimezone(_ text: String, metadata: ChannelMetadata, userDefault: TimeZone) -> TimeZone`

**Entity Types:**
- `person` - Names, roles (matched against Contacts when possible)
- `organization` - Company names, institutions
- `date` - Absolute and relative dates/times
- `daterange` - Date ranges with start/end
- `amount` - Money, percentages
- `location` - Addresses, cities, states, countries
- `contact` - Emails, phone numbers, handles, URLs
- `identifier` - Invoice numbers, confirmation codes, tracking numbers
- `thing` - Products, services, topics (coarse taxonomy)

**Integration with Existing Code:**
- Extends `hostagent/Sources/Entity/EntityService.swift` functionality
- Reuses `hostagent/Sources/OCR/OCRService.swift` for document extraction
- Leverages `hostagent/Sources/Email/EmailBodyExtractor.swift` for text cleaning

#### 2.1.3 Intent Classifier Module (`src/haven/intents/classifier/`)

Python module for multi-label intent detection.

**Responsibilities:**
- Load and validate intent taxonomy
- Classify artifacts (with pre-processed entities) for zero or more intents
- Compute confidence scores
- Apply channel-aware priors
- Handle taxonomy versioning

**Key Functions:**
- `load_taxonomy(version) -> IntentTaxonomy`
- `classify(artifact, entities, taxonomy) -> List[IntentCandidate]`
- `compute_confidence(intent, artifact, entities, priors) -> float`
- `apply_priors(intents, channel_metadata) -> List[IntentCandidate]`

**Note:** Receives entities pre-processed by Haven.app; focuses on intent classification using LLM or rule-based approaches.

#### 2.1.4 Slot Filler Module (`src/haven/intents/slots/`)

Module for populating intent slots from entities and text.

**Responsibilities:**
- Map entities to slot requirements
- Extract slot values from free text when entities unavailable
- Validate slot constraints (types, enums, ranges)
- Mark missing required slots
- Generate evidence references

**Key Functions:**
- `fill_slots(intent, entities, text, taxonomy) -> SlotValues`
- `extract_from_text(slot_def, text, entities) -> Optional[SlotValue]`
- `validate_slots(slots, intent_def) -> ValidationResult`
- `generate_evidence(slot_value, text, entities) -> Evidence`

#### 2.1.5 Signal Validator Module (`src/haven/intents/validation/`)

Module for schema validation and signal construction.

**Responsibilities:**
- Validate Intent Signal schema
- Ensure evidence completeness
- Check required fields
- Generate stable signal IDs
- Enforce deterministic field ordering

**Key Functions:**
- `validate_signal(signal_dict, schema_version) -> ValidationResult`
- `construct_signal(artifact_id, intents, entities, evidence) -> IntentSignal`
- `generate_signal_id(artifact_id, intent_names, taxonomy_version) -> str`

### 2.2 Data Models

#### 2.2.1 Artifact Input Schema

```python
class ArtifactInput(BaseModel):
    """Input payload for intent processing (includes pre-processed entities from Haven.app)"""
    artifact_id: str  # Stable, unique within Haven
    source: Literal["imessage", "email", "notes", "ocr_image", "pdf_page", "file_text"]
    channel_metadata: Dict[str, Any]  # sender, recipients, thread_id, subject
    observed_at: datetime
    timezone_hint: Optional[str]  # IANA or offset
    parent_thread_id: Optional[str]
    
    # Content
    text: str  # UTF-8, may be empty if image/PDF only
    html: Optional[str]
    attachments: List[AttachmentDescriptor]
    
    # Pre-processed Entities (from Haven.app)
    entities: EntitySet  # REQUIRED - entities extracted client-side
    
    # Provenance
    collection_time: datetime
    source_locator: str  # mailbox/folder msg id, chat guid, file path hash
    
    # Processing hints
    allowed_intents: Optional[List[str]]
    language_hint: Optional[str]  # BCP-47
    user_prefs: Optional[UserPreferences]
    
    # Client-side processing metadata
    ner_processing_timestamp: Optional[datetime]  # When NER was performed
    ner_version: Optional[str]  # Version of NER processor used
```

#### 2.2.2 Entity Schema

```python
class Entity(BaseModel):
    """Extracted entity with provenance"""
    type: str  # person, date, amount, location, etc.
    value: str  # Original text value
    normalized_value: str  # Canonical form
    start_offset: int  # Character offset in text
    end_offset: int
    evidence: str  # Preview snippet
    confidence: float  # 0-1
    source_layer: str  # "text", "ocr", "metadata"
    
    # Optional fields
    page: Optional[int]  # For OCR/PDF
    block_id: Optional[str]
    line_id: Optional[str]
    quoted: Optional[bool]  # True if from quoted/forwarded content
    ambiguous: Optional[bool]  # True if multiple resolutions possible
    resolution_basis: Optional[str]  # "text", "metadata", "timezone_hint"
```

#### 2.2.3 EntitySet Schema

```python
class EntitySet(BaseModel):
    """Complete entity extraction results"""
    detected_languages: List[Language]  # [{code, confidence}]
    people: List[Entity] = []
    organizations: List[Entity] = []
    dates: List[Entity] = []
    dateranges: List[Entity] = []
    amounts: List[Entity] = []
    locations: List[Entity] = []
    contacts: List[Entity] = []
    identifiers: List[Entity] = []
    things: List[Entity] = []
    
    # Document layout (if applicable)
    document_layout: Optional[DocumentLayout]
    
    # Normalization notes
    normalization_notes: List[str] = []
```

#### 2.2.4 Intent Signal Schema

```python
class IntentSignal(BaseModel):
    """Output Intent Signal with strict schema"""
    signal_id: str  # Unique, stable
    artifact_id: str
    taxonomy_version: str
    
    intents: List[IntentResult]
    global_confidence: Optional[float]  # 0-1 overall score
    
    processing_notes: List[str] = []
    processing_timestamps: ProcessingTimestamps
    provenance: Provenance
    
    # Thread context
    parent_thread_id: Optional[str]
    
    # Conflict handling
    conflict: bool = False
    conflicting_fields: List[str] = []

class IntentResult(BaseModel):
    """Single intent with slots and evidence"""
    name: str  # Must exist in taxonomy
    confidence: float  # 0-1
    slots: Dict[str, Any]  # Typed values per taxonomy
    missing_slots: List[str] = []
    follow_up_needed: bool = False
    follow_up_reason: Optional[str]
    
    evidence: Evidence

class Evidence(BaseModel):
    """Evidence supporting the intent and slots"""
    text_spans: List[TextSpan]  # {start_offset, end_offset, preview}
    layout_refs: List[LayoutRef] = []  # {attachment_id, page, block_id, line_id}
    entity_refs: List[EntityRef]  # {type, index} pointing into entities

class ProcessingTimestamps(BaseModel):
    """Timing information"""
    # Client-side (Haven.app)
    ner_started_at: Optional[datetime]  # When NER started in Haven.app
    ner_completed_at: Optional[datetime]  # When NER completed in Haven.app
    
    # Server-side (Intents Service)
    received_at: datetime  # When artifact received by Intents Service
    intent_started_at: datetime
    intent_completed_at: datetime
    emitted_at: datetime

class Provenance(BaseModel):
    """Processing provenance"""
    ner_version: str  # Version of NER processor (from Haven.app)
    ner_framework: str  # e.g., "NaturalLanguage-macOS-14.0"
    classifier_version: str
    slot_filler_version: str
    config_snapshot_id: str
    processing_location: Literal["client", "server", "hybrid"]  # Where processing occurred
```

#### 2.2.3 Intent Taxonomy Schema

```python
class IntentTaxonomy(BaseModel):
    """Versioned intent taxonomy definition"""
    version: str
    created_at: datetime
    intents: Dict[str, IntentDefinition]

class IntentDefinition(BaseModel):
    """Definition of a single intent"""
    name: str
    description: str
    slots: Dict[str, SlotDefinition]
    constraints: Optional[Dict[str, Any]]  # Cross-slot validation rules

class SlotDefinition(BaseModel):
    """Definition of a slot"""
    name: str
    type: Literal["string", "datetime", "date", "amount", "person", "location", "enum"]
    required: bool
    constraints: Optional[Dict[str, Any]]  # enum values, regex, min/max, ISO formats
    description: Optional[str]
```

### 2.3 Database Schema

#### 2.3.1 Documents Table Updates

```sql
-- Add intent_status column to documents table
ALTER TABLE documents 
ADD COLUMN intent_status TEXT NOT NULL DEFAULT 'pending',
ADD COLUMN intent_processing_started_at TIMESTAMPTZ,
ADD COLUMN intent_processing_completed_at TIMESTAMPTZ,
ADD COLUMN intent_processing_error TEXT;

-- Add constraint for intent_status
ALTER TABLE documents
ADD CONSTRAINT documents_valid_intent_status CHECK (
    intent_status IN ('pending', 'processing', 'processed', 'failed', 'skipped')
);

-- Index for worker polling
CREATE INDEX idx_documents_intent_status ON documents(intent_status, created_at) 
WHERE intent_status = 'pending';

-- Index for querying processed documents
CREATE INDEX idx_documents_intent_processed ON documents(intent_status, intent_processing_completed_at DESC)
WHERE intent_status = 'processed';
```

#### 2.3.2 New Tables

```sql
-- Intent Signals storage
CREATE TABLE intent_signals (
    signal_id UUID PRIMARY KEY,
    artifact_id UUID NOT NULL REFERENCES documents(doc_id),
    taxonomy_version VARCHAR(50) NOT NULL,
    parent_thread_id UUID REFERENCES threads(thread_id),
    
    -- Signal data (JSONB for flexibility, validated by application)
    signal_data JSONB NOT NULL,
    
    -- Status and feedback
    status VARCHAR(20) DEFAULT 'pending',  -- pending, confirmed, edited, rejected, snoozed
    user_feedback JSONB,  -- {action, corrected_slots, timestamp, user_id}
    
    -- Conflict handling
    conflict BOOLEAN DEFAULT FALSE,
    conflicting_fields TEXT[],
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Indexes
    CONSTRAINT valid_status CHECK (status IN ('pending', 'confirmed', 'edited', 'rejected', 'snoozed'))
);

CREATE INDEX idx_intent_signals_artifact ON intent_signals(artifact_id);
CREATE INDEX idx_intent_signals_thread ON intent_signals(parent_thread_id);
CREATE INDEX idx_intent_signals_status ON intent_signals(status);
CREATE INDEX idx_intent_signals_taxonomy ON intent_signals(taxonomy_version);
CREATE INDEX idx_intent_signals_created ON intent_signals(created_at DESC);

-- GIN index for JSONB queries
CREATE INDEX idx_intent_signals_data ON intent_signals USING GIN (signal_data);

-- Entity cache (TTL configurable)
CREATE TABLE entity_cache (
    cache_key VARCHAR(255) PRIMARY KEY,  -- hash(artifact_id + text_hash)
    artifact_id UUID NOT NULL REFERENCES documents(doc_id),
    entity_set JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_entity_cache_expires ON entity_cache(expires_at);
CREATE INDEX idx_entity_cache_artifact ON entity_cache(artifact_id);

-- Taxonomy versions
CREATE TABLE intent_taxonomies (
    version VARCHAR(50) PRIMARY KEY,
    taxonomy_data JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by VARCHAR(255),
    change_notes TEXT
);

-- User preferences for intents
CREATE TABLE intent_user_preferences (
    user_id VARCHAR(255) PRIMARY KEY,  -- For multi-user support, 'default' for single user
    preferences JSONB NOT NULL,  -- {intent_name: {automation_level, thresholds}, ...}
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Deduplication tracking
CREATE TABLE intent_deduplication (
    dedupe_key VARCHAR(255) PRIMARY KEY,  -- hash(thread_id + intent_name + normalized_slots)
    signal_id UUID NOT NULL REFERENCES intent_signals(signal_id),
    thread_id UUID REFERENCES threads(thread_id),
    intent_name VARCHAR(100) NOT NULL,
    normalized_slots_hash VARCHAR(64) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    window_end_at TIMESTAMPTZ NOT NULL  -- For TTL-based cleanup
);

CREATE INDEX idx_intent_dedup_window ON intent_deduplication(window_end_at);
CREATE INDEX idx_intent_dedup_thread ON intent_deduplication(thread_id);
```

## 3. Processing Pipeline

### 3.1 Pipeline Flow

**Client-Side (Haven.app):**
```
1. Artifact Collected (iMessage, Email, Notes, File)
   ↓
2. Text Extraction & Normalization
   ├─→ Extract clean text (remove signatures, quoted content)
   └─→ HTML to plain text conversion (if needed)
   ↓
3. OCR/Document Extraction (if attachments)
   └─→ Extract text from images/PDFs using Vision framework
   ↓
4. Language Detection
   └─→ NLLanguageRecognizer
   ↓
5. NER Preprocessing (Native macOS Frameworks)
   ├─→ Extract entities using NLTagger
   │   ├─→ People, Organizations, Places
   │   ├─→ Dates, Times
   │   └─→ Addresses
   ├─→ Match contacts using Contacts framework
   ├─→ Normalize locations using CoreLocation
   ├─→ Extract patterns (emails, phones, URLs, identifiers)
   ├─→ Canonicalize values
   ├─→ Resolve timezones
   └─→ Link duplicates
   ↓
6. Package Artifact + Entities
   └─→ Send to Gateway via HTTP
```

**Server-Side (Intents Worker - Queue-Based):**
```
7. Document persisted with intent_status = 'pending'
   ↓
8. Worker polls database for pending documents
   ├─→ SELECT ... WHERE intent_status = 'pending'
   ├─→ FOR UPDATE SKIP LOCKED (atomic claim)
   └─→ UPDATE intent_status = 'processing'
   ↓
9. Load Taxonomy & User Preferences
   ↓
10. Intent Classification
    ├─→ Multi-label detection (using LLM or rules)
    ├─→ Apply channel priors
    └─→ Compute confidences
    ↓
11. Slot Filling (per intent)
    ├─→ Map entities to slots
    ├─→ Extract from text if needed
    └─→ Validate constraints
    ↓
12. Evidence Generation
    ├─→ Text spans
    ├─→ Entity references
    └─→ Layout references (if OCR)
    ↓
13. Deduplication Check
    ├─→ Compare with thread signals
    └─→ Suppress if duplicate
    ↓
14. Thread-Aware Merging (if applicable)
    ├─→ Merge complementary slots
    └─→ Detect conflicts
    ↓
15. Schema Validation
    ↓
16. Emit Intent Signal
    ├─→ Persist signal to intent_signals table
    ├─→ UPDATE intent_status = 'processed'
    └─→ UPDATE intent_processing_completed_at
```

### 3.2 Processing Modes

#### 3.2.1 Queue-Based Processing (Default)

- Documents automatically queued when persisted with `intent_status = 'pending'`
- Worker continuously polls and processes documents
- Low latency target (P95 ≤ 2-5 seconds from ingestion to signal)
- Signals available shortly after ingestion
- Suitable for: all new artifacts (messages, files, notes)

**Worker Behavior:**
- Polls every 2 seconds (configurable)
- Processes up to 8 documents per batch (configurable)
- Uses PostgreSQL `FOR UPDATE SKIP LOCKED` for atomic job claiming
- Multiple workers can run in parallel (horizontal scaling)

#### 3.2.2 Selective Reprocessing

- Manually set `intent_status = 'pending'` for specific documents
- Worker picks up and reprocesses
- Generate new signals alongside old (for comparison)
- Suitable for: taxonomy evolution, model updates, user corrections

**Reprocessing Workflow:**
```sql
-- Mark documents for reprocessing
UPDATE documents 
SET intent_status = 'pending',
    intent_processing_completed_at = NULL
WHERE doc_id IN (...);
-- Worker will pick them up automatically
```

### 3.3 Error Handling

**Schema Validation Failures:**
- Exclude invalid intent candidates
- Include `validation_error` in `processing_notes`
- Continue processing other intents

**Ambiguous Dates/Times:**
- Mark `ambiguous: true`
- Include all candidate resolutions
- Do not auto-fill required slots above thresholds

**Missing Attachments:**
- Mark `attachment_unavailable: true`
- Proceed with available text/entities
- Include note in `processing_notes`

**Corrupt Input:**
- Mark document `intent_status = 'failed'`
- Set `intent_processing_error` with failure details
- Emit no-intent signal (optional, for audit)
- Include failure explanation in `processing_notes`
- Log error for telemetry

**Worker-Specific Error Handling:**
- **Processing Timeout**: Mark as 'failed', set error message, allow retry by resetting to 'pending'
- **Database Connection Loss**: Worker retries connection, jobs remain 'processing' until timeout
- **LLM Service Unavailable**: Mark as 'failed', include retry logic (exponential backoff)
- **Partial Failures**: If some intents succeed, emit signals for successful intents, mark document as 'processed' with notes about failures

## 4. Integration Points

### 4.1 Gateway Integration

**Automatic Queueing:**
- When Catalog persists a document, it automatically sets `intent_status = 'pending'`
- No explicit API call needed - documents are queued automatically
- Worker picks up pending documents asynchronously

**New Gateway Endpoints (for querying signals):**

```python
# Gateway routes (services/gateway_api/routes/intents.py)

@router.get("/v1/intents/signals")
async def query_signals(
    artifact_id: Optional[str] = None,
    thread_id: Optional[str] = None,
    intent_name: Optional[str] = None,
    status: Optional[str] = None,
    start_date: Optional[datetime] = None,
    end_date: Optional[datetime] = None
):
    """Query intent signals with filters"""
    # Forward to Intents API service
    pass

@router.get("/v1/intents/signals/{signal_id}")
async def get_signal(signal_id: str):
    """Retrieve a specific signal"""
    # Forward to Intents API service
    pass

@router.post("/v1/intents/feedback")
async def submit_feedback(
    signal_id: str,
    action: Literal["confirm", "edit", "reject", "snooze"],
    corrected_slots: Optional[Dict[str, Any]] = None
):
    """Submit user feedback on a signal"""
    # Forward to Intents API service
    pass

@router.get("/v1/intents/status/{doc_id}")
async def get_processing_status(doc_id: str):
    """Check intent processing status for a document"""
    # Query documents.intent_status directly or via Catalog
    pass
```

**Gateway Hooks:**

- After artifact ingestion: Documents automatically queued (no action needed)
- Before search results: Include matching signals
- User action handlers: Route confirmed signals to action executors (future)

### 4.2 Catalog Integration

**Automatic Queueing:**
- When Catalog persists a document via `/v1/catalog/documents`, it sets `intent_status = 'pending'`
- Documents are automatically queued for intent processing
- No additional API call required

**New Catalog Endpoints:**

```python
# Catalog routes (services/catalog_api/routes/intents.py)

@router.post("/v1/catalog/intent-signals")
async def create_intent_signal(signal: IntentSignal):
    """Persist an intent signal (called by Intents Worker)"""
    # Validate schema
    # Insert into intent_signals table
    # Update deduplication tracking
    # Update document.intent_status = 'processed'
    pass

@router.get("/v1/catalog/intent-signals/{signal_id}")
async def get_intent_signal(signal_id: str):
    """Retrieve a signal by ID"""
    pass

@router.patch("/v1/catalog/intent-signals/{signal_id}/feedback")
async def update_signal_feedback(
    signal_id: str,
    feedback: UserFeedback
):
    """Update signal with user feedback"""
    pass

@router.get("/v1/catalog/documents/{doc_id}/intent-status")
async def get_intent_status(doc_id: str):
    """Get intent processing status for a document"""
    # Returns intent_status, processing timestamps, error if any
    pass
```

**Catalog Queries:**

- Join signals with documents for search
- Filter documents by intent presence
- Aggregate signal statistics per thread/document
- Query documents by `intent_status` for monitoring

### 4.3 Collector Integration

**Haven.app Integration:**
- Collectors in Haven.app perform NER preprocessing before sending artifacts to Gateway
- NER preprocessing happens automatically during collection (iMessage, Email, Notes, Files)
- Entities are extracted using native macOS frameworks and included in the artifact payload
- Gateway receives artifacts with pre-processed entities and forwards to Catalog
- Catalog persists documents with `intent_status = 'pending'` (automatic queueing)
- Intents Worker picks up pending documents asynchronously

**Implementation in Haven.app:**
- Collectors call `NERPreprocessor.extractEntities()` after collecting artifact content
- Entities are serialized to JSON and included in the HTTP payload to Gateway
- Processing happens synchronously during collection (or async for bulk operations)
- No changes needed to collector code - queueing is automatic

**Legacy Collector Support:**
- CLI collectors (Python) can optionally perform basic NER or send artifacts without entities
- Documents are still queued automatically (intent_status = 'pending')
- Worker can handle documents with or without pre-processed entities (fallback to server-side NER if needed)

**Optional Enhancements:**
- Collectors could include `processing_hints` in payloads
- Channel-specific metadata aids intent detection
- Batch NER processing for bulk operations to optimize performance

## 5. Configuration & Taxonomy Management

### 5.1 Taxonomy Storage

**Format:** JSON/YAML files in `services/intents_service/taxonomies/`

**Example Structure:**

```yaml
version: "1.0.0"
created_at: "2024-01-01T00:00:00Z"
intents:
  task.create:
    description: "Create a new task or todo item"
    slots:
      what:
        type: string
        required: true
        description: "Task description"
      due_date:
        type: datetime
        required: false
        constraints:
          min: "now"
      assignee:
        type: person
        required: false
      source_ref:
        type: string
        required: true
        description: "Reference to source artifact"
    constraints:
      - if: due_date
        then: due_date >= now
  
  schedule.create:
    description: "Schedule a calendar event"
    slots:
      start_dt:
        type: datetime
        required: true
      end_dt:
        type: datetime
        required: false
        constraints:
          min_field: start_dt
      location:
        type: location
        required: false
      participants:
        type: array[person]
        required: false
      source_ref:
        type: string
        required: true
```

### 5.2 Configuration Management

**Service Configuration (`services/intents_service/config.yaml`):**

```yaml
# Processing
processing:
  realtime_timeout_seconds: 5
  batch_timeout_seconds: 60
  max_concurrent_artifacts: 10

# Confidence thresholds
thresholds:
  auto_commit:
    task.create: 0.85
    schedule.create: 0.90
    reminder.create: 0.80
    default: 0.75
  review:
    task.create: 0.60
    schedule.create: 0.65
    reminder.create: 0.55
    default: 0.50

# Deduplication
deduplication:
  window_hours: 24
  keys:
    - thread_id
    - intent_name
    - normalized_slots_hash

# Entity cache
entity_cache:
  enabled: true
  ttl_hours: 168  # 7 days

# Privacy
privacy:
  local_only: true
  remote_processing_opt_in: false
```

### 5.3 Version Control

- Taxonomies stored in versioned files
- Database tracks active taxonomy version per signal
- Support multiple active versions during migration
- Replay capability for taxonomy updates

## 6. User Feedback & Controls

### 6.1 Feedback Capture

**Feedback Actions:**
- `confirm` - User approves the signal
- `edit` - User corrects slot values
- `reject` - User dismisses the signal
- `snooze` - User defers action

**Feedback Storage:**

```python
class UserFeedback(BaseModel):
    signal_id: str
    action: Literal["confirm", "edit", "reject", "snooze"]
    corrected_slots: Optional[Dict[str, Any]]
    timestamp: datetime
    user_id: Optional[str]
    notes: Optional[str]
```

### 6.2 User Preferences

**Preference Structure:**

```python
class UserPreferences(BaseModel):
    automation_levels: Dict[str, Literal["auto", "ask", "log_only"]]
    channel_sensitivity: Dict[str, Dict[str, Any]]  # per-channel rules
    quiet_hours: Optional[QuietHours]
    allowed_domains: List[str]  # for auto-actions
    blocked_contacts: List[str]
```

**Preference Application:**
- Loaded at signal generation time
- Snapshot stored in signal provenance
- Affects confidence thresholds and surfacing decisions

## 7. Privacy & Security

### 7.1 Local-First Processing

- **NER Preprocessing**: Always occurs locally in Haven.app using native macOS frameworks
- **Intent Classification**: Defaults to local processing; remote processing requires explicit opt-in per source category
- **Privacy**: Entity extraction never leaves the device; only canonicalized entities sent to Gateway
- Audit log tracks processing location for all stages

### 7.2 Data Minimization

- Only evidence-referenced data included in signals
- PII redaction for non-evidence fields
- Configurable retention TTLs

### 7.3 Access Control

- Signals inherit source artifact ACLs
- User feedback requires authentication
- Telemetry excludes PII

### 7.4 Auditability

- Every signal includes processing provenance
- Taxonomy versions tracked
- User feedback logged with timestamps
- Processing location recorded

## 8. Performance & Reliability

### 8.1 Latency Targets

- **Client-Side NER**: P95 ≤ 500ms per artifact (using native frameworks)
- **Server-Side Intent Processing**: P95 ≤ 2-3 seconds per artifact
- **End-to-End (NER + Intent)**: P95 ≤ 5 seconds per artifact
- **Batch**: P95 ≤ 60 seconds per artifact
- **Throughput**: 100+ artifacts/second (batch mode, server-side)

### 8.2 Reliability

- **Idempotency**: Reprocessing produces identical signals (save timestamps)
- **Backpressure**: Queue with exponential backoff
- **Retry**: Configurable retry policies for transient failures
- **Graceful Degradation**: Continue processing other intents if one fails

### 8.3 Scalability

- **Queue-Based Architecture**: Natural backpressure via database queue
- **Horizontal Scaling**: Multiple worker instances can run in parallel
  - Each worker polls independently using `FOR UPDATE SKIP LOCKED`
  - No coordination needed between workers
  - Linear scaling with number of workers
- **Batch Processing**: Configurable batch size (default 8) for throughput optimization
- **Stateless Workers**: Workers are stateless, can be scaled up/down dynamically
- **Database as Queue**: PostgreSQL provides reliable, transactional queue semantics

## 9. Telemetry & Metrics

### 9.1 Key Metrics

**Coverage:**
- % artifacts producing ≥1 signal
- % artifacts with no intent (below threshold)

**Quality:**
- Confirm rate per intent
- Reject rate per intent
- Edit rate per intent
- Average confidence per intent

**Performance:**
- Processing latency (P50, P95, P99)
- Queue depth (pending documents count)
- Worker throughput (documents/second per worker)
- Processing time per document
- Cache hit rate

**Stability:**
- Schema validation failure count
- Taxonomy version distribution
- Drift indicators (sudden volume/confidence changes)

### 9.2 Error Tracking

**Error Categories:**
- Entity extraction failures
- Slot validation failures
- Schema validation failures
- Ambiguous resolution cases

**Top Errors:**
- Categorized by type and intent
- Tracked over time for trend analysis

## 10. Implementation Phases

### Phase 1: MVP (Core Functionality)

**Scope:**
- **Client-Side (Haven.app)**: Basic NER preprocessing using NaturalLanguage framework (dates, people, amounts, contacts)
- **Server-Side**: Single-label intent detection (expand to multi-label)
- Core intent taxonomy (task.create, schedule.create, reminder.create)
- Schema validation and signal emission
- Basic deduplication

**Deliverables:**
- **Haven.app**: `NERPreprocessor` Swift module extending `EntityService`
  - Language detection with `NLLanguageRecognizer`
  - Entity extraction with `NLTagger`
  - Entity serialization to JSON
- **Intents Worker**: Queue-based worker (`services/intents_service/worker.py`)
  - Database polling loop
  - Atomic job claiming (`FOR UPDATE SKIP LOCKED`)
  - Status tracking (pending → processing → processed/failed)
- **Intents API Service**: Lightweight FastAPI service for querying signals
- Intent classifier (LLM-based or rule-based)
- Slot filler with entity mapping
- Database schema (intent_status column, intent_signals table)
- Gateway integration (query endpoints)

### Phase 2: Enhanced NER & Multi-Label

**Scope:**
- **Client-Side (Haven.app)**: Full entity type coverage
  - Contact matching using Contacts framework
  - Location normalization using CoreLocation
  - Pattern extraction (identifiers, tracking codes)
  - OCR/document extraction integration (Vision framework)
- **Server-Side**: Multi-label intent detection
- Thread-aware merging
- Conflict detection
- User feedback capture

**Deliverables:**
- **Haven.app**: Enhanced `NERPreprocessor` with all entity types
  - Contact matching and normalization
  - Location geocoding
  - Pattern-based entity extraction
- **Intents Service**: Multi-label classifier
- Thread context integration
- Feedback API and storage

### Phase 3: Advanced Features

**Scope:**
- Full taxonomy management
- Advanced deduplication
- User preferences and automation levels
- Telemetry dashboard
- Selective reprocessing

**Deliverables:**
- Taxonomy versioning system
- Preference management
- Comprehensive telemetry
- Reprocessing pipeline

## 11. Open Questions & Decisions Needed

### 11.1 Model Selection

- **NER**: ✅ **DECIDED** - Native macOS frameworks (NaturalLanguage, Vision, Contacts, CoreLocation) in Haven.app
- **Intent Classification**: Fine-tuned model vs. prompt-based LLM?
- **Slot Filling**: Rule-based vs. LLM-based extraction?

**Recommendation**: 
- NER uses native frameworks (already decided)
- Intent classification: Start with prompt-based LLM (Ollama/local) for flexibility, optimize later
- Slot filling: Hybrid approach - use entities first, LLM extraction for missing slots

### 11.2 Default Taxonomy & Thresholds

- What are the MVP intent definitions?
- What are the default confidence thresholds?
- Which entity types are MVP-critical?

**Recommendation**: Start with the 8 intents listed in requirements, thresholds at 0.75/0.50.

### 11.3 Deduplication Strategy

- What are the deduplication keys?
- How to handle cross-channel duplicates?
- What is the deduplication window?

**Recommendation**: Use thread_id + intent_name + normalized_slots_hash, 24-hour window.

### 11.4 User Preferences Representation

- Snapshot at signal time vs. lookup at action time?
- How to handle preference changes retroactively?

**Recommendation**: Snapshot at signal time for auditability, allow reprocessing on preference change.

### 11.5 Telemetry Privacy Balance

- What is the minimal telemetry set?
- How to balance improvement with privacy?

**Recommendation**: Aggregate metrics only, no PII, user opt-out available.

## 12. Acceptance Criteria

### AC-1: Schema Validation
100% of emitted signals validate against published schema with `additionalProperties: false`.

### AC-2: Evidence Completeness
For each filled slot, at least one evidence reference is present (text span or entity ref).

### AC-3: Date Resolution
Relative times ("next Friday at 3") correctly resolve to absolute ISO datetimes with timezone for top 5 locales; ambiguous cases flagged.

### AC-4: Deduplication
Sending the same email into two mailboxes results in one surfaced signal after dedup (within window).

### AC-5: No-Intent Handling
Non-actionable newsletters produce `intents: []` ≥ 80% of the time in curated test set.

### AC-6: Feedback Loop
Confirm/reject/edit actions are stored with linkage to originating signal for audit.

### AC-7: Privacy
When remote processing is disabled, no external calls are made; audit log shows local-only pipeline.

## 13. References

- Functional Requirements Document (provided)
- Haven Architecture Overview (`docs/architecture/overview.md`)
- Haven Technical Reference (`documentation/technical_reference.md`)
- Unified Schema v2 (`documentation/SCHEMA_V2_REFERENCE.md`)

