# Beads backlog (snapshot)

_Generated: 2025-10-21T18:53:16.539408Z_

This file lists beads issues in the backlog. Use the table of contents to navigate to specific items.

## Details

### haven-1 - POC: Hostagent → Gateway → Neo4j (Life Graph)

Status: **in_progress**

```md
Stand up Neo4j in compose, add Gateway POC routes, call Hostagent for iMessage crawl (N/X days), run native extraction & merges, idempotent upsert to Neo4j, provide validation queries.
```
---

### haven-4 - Unit 2: Catalog → Contacts export normalization (E.164/email)

Status: **open**

Priority: **1**

```md
Ensure Catalog can export normalized contacts for identity resolution
```
---

### haven-5 - Unit 3: Hostagent POST /poc/crawl (threads/messages/extract)

Status: **open**

```md
Add POC endpoint to hostagent for thread discovery, message extraction, and native NL processing
```
---

### haven-6 - Unit 4: Span→message offset mapping

Status: **open**

Priority: **1**

```md
Map NL entity spans to message offsets for proper attribution
```
---

### haven-7 - Unit 5: Task heuristics + assignee + place merge (thread-scoped)

Status: **open**

Priority: **1**

```md
Implement conversation-aware heuristics for task detection, assignee resolution, and place entity merging within thread context
```
---

### haven-12 - Unit 9 (docs): README_poc.md — finalize after units 2/4/5/8

Status: **open**

Priority: **1**

```md
Final POC README with 3–4 commands to run and verification steps. This task must wait until Units 2, 4, 5, and 8 are complete.
```
---

### haven-13 - Epic: Finish Hostagent — build, run, test, and integrate

Status: **open**

Priority: **1**

```md
Complete the Hostagent native macOS service so it can be built, installed, run as a LaunchAgent, collect iMessage/contact/fs data, perform Vision OCR, and integrate reliably with Gateway and Neo4j POC. Include tests and documentation.

Scope/Checklist:
- Build and packaging: `make install`, `make run`, `make dev`, `make launchd` documented and working on macOS.
- Collectors: iMessage, Contacts, localfs collectors updated to use hostagent API; deprecated Python collectors marked.
- OCR/vision: integrate native Vision OCR endpoint `/v1/ocr` and replace legacy `imdesc.swift` usage.
- FS watch: FSEvents-based uploads with presigned URL flows to Gateway/minio.
- Gateway integration: Gateway POC routes (`/poc/hostagent/run`, `/poc/hostagent/status`) fully functional and tested end-to-end.
- Neo4j POC: ensure hostagent-produced entities can be ingested into Gateway -> Neo4j flow.
- Tests: unit tests for hostagent logic, and an end-to-end smoke test that simulates collectors with `--simulate` and verifies Gateway ingestion.
- Docs: `hostagent/QUICKSTART.md` and update `AGENTS.md` with final run instructions and TCC/FDA notes.

Acceptance criteria:
- Hostagent builds and installs locally on macOS via `make install`.
- `make launchd` successfully installs a user LaunchAgent and `make health` returns 200.
- End-to-end simulated collector run posts data to Gateway and the Gateway accepts it (200) in CI-like dry-run.
- All new/changed functionality covered by unit tests; `pytest` passes for hostagent/test files.

Notes:
- This epic may depend on Units 2/4/5 for catalog/contact exports and span mapping for precise attribution.
- Use existing `hostagent/Makefile` and follow `hostagent/QUICKSTART.md` conventions.

```
---

### haven-16 - Hostagent: Complete FS watch endpoints

Status: **open**

Priority: **2**

```md
Finish FSEvents-based file system watch implementation with presigned URL uploads.

Tasks:
- Complete POST /v1/fs-watches endpoint (register new watch)
- Complete GET /v1/fs-watches (list active watches)
- Complete DELETE /v1/fs-watches/{id} (remove watch)
- Complete GET /v1/fs-watches/events (poll event queue)
- Complete POST /v1/fs-watches/events:clear (clear queue)
- Implement FSEvents watcher that detects file changes in monitored directories
- Integrate with Gateway to request presigned URLs for uploads
- Upload files to minio via presigned URLs when changes detected
- Add proper error handling for permission issues, missing directories

Acceptance:
- Can register a watch on ~/Documents and see file change events
- Events include file path, event type (created/modified/deleted), timestamp
- Files are uploaded to minio via presigned URLs
- Watch state persists across hostagent restarts (if needed)
```
---

### haven-17 - Hostagent: Stub Contacts collector endpoint

Status: **open**

Priority: **1**

Labels: contacts_collector

```md
Create stub POST /v1/collectors/contacts:run endpoint for future Contacts.app integration.

Tasks:
- Create ContactsHandler.swift with POST /v1/collectors/contacts:run route
- Return empty/stub JSON response matching expected schema
- Add basic error handling and auth
- Document requirements (pyobjc, TCC permissions) for future implementation
- Mark as stub/not-implemented in capabilities response

Acceptance:
- Endpoint exists and returns 200 with stub data
- Gateway can call it without errors
- Documentation notes it's a stub for future work
```
---

### haven-18 - Hostagent: Update Gateway POC routes for hostagent

Status: **open**

Priority: **2**

```md
Update Gateway's /poc/hostagent/* endpoints to properly orchestrate hostagent collectors.

Tasks:
- Update POST /poc/hostagent/run to call hostagent's /v1/collectors/imessage:run
- Update GET /poc/hostagent/status to poll hostagent's state endpoints
- Add proper error handling for hostagent connection failures
- Add retry logic with backoff for transient failures
- Update config to use host.docker.internal:7090 for hostagent URL
- Add observability logging for hostagent calls (timing, status, errors)

Acceptance:
- Gateway POC route successfully triggers hostagent collector
- Status endpoint returns accurate progress from hostagent
- Errors are logged and returned with helpful messages
- Integration works from inside Docker container to host agent
```
---

### haven-19 - Hostagent: Unit tests for core modules

Status: **open**

Priority: **1**

```md
Create comprehensive unit tests for hostagent Swift modules.

Tasks:
- Create Tests/HostHTTPTests for HTTP handlers (health, capabilities, OCR, entities)
- Create Tests/IMessagesTests for iMessage collector logic
- Create Tests/FSWatchTests for filesystem watch logic
- Create Tests/OCRTests for Vision OCR module
- Create Tests/EntityTests for NL entity extraction
- Add test fixtures (sample images, chat.db snapshot, config files)
- Ensure tests can run in CI without macOS-specific dependencies where possible
- Add make test target that runs all tests

Acceptance:
- swift test passes all tests
- Test coverage for critical paths (OCR, entity extraction, iMessage parsing)
- Tests are documented and can be run locally
```
---

### haven-20 - Hostagent: End-to-end smoke test

Status: **open**

Priority: **1**

```md
Create end-to-end smoke test that validates full hostagent → Gateway integration.

Tasks:
- Create scripts/test_hostagent_e2e.py or .sh script
- Start hostagent locally (or verify it's running)
- Call POST /v1/collectors/imessage:run with simulate/small batch
- Verify hostagent returns valid JSON
- Post returned data to Gateway /v1/documents endpoint
- Verify Gateway accepts and stores the data (200 response)
- Query Gateway search to verify data is indexed
- Add to CI/docs as integration test example

Acceptance:
- Script runs successfully on local macOS dev machine
- Data flows from hostagent → Gateway → storage without errors
- Script documents the full flow for future reference
```
---

### haven-21 - Hostagent: Update AGENTS.md and QUICKSTART.md

Status: **open**

Priority: **1**

```md
Update documentation to reflect completed hostagent implementation.

Tasks:
- Update AGENTS.md with final hostagent architecture notes
- Document all hostagent endpoints with examples
- Update collector deprecation notices (mark Python collectors as legacy)
- Add TCC/FDA permission requirements and setup instructions
- Update hostagent/QUICKSTART.md with final run instructions
- Add troubleshooting section for common issues
- Document how to verify hostagent is working (health checks, logs)
- Add examples of calling each endpoint from curl and from Docker

Acceptance:
- AGENTS.md accurately reflects current architecture
- QUICKSTART.md has clear step-by-step setup instructions
- All endpoints are documented with request/response examples
- Permission requirements and troubleshooting are clear
```
---

### haven-23 - Hostagent: Port macOS Contacts collector (collector_contacts.py) to Swift

Status: **open**

Priority: **2**

Labels: contacts_collector

```md
Port the Python Contacts collector (`scripts/collectors/collector_contacts.py`) into the native Hostagent Swift service as a collector endpoint.

Scope/Tasks:
- Add `POST /v1/collectors/contacts:run` and `GET /v1/collectors/contacts/state` endpoints in hostagent.
- Implement safe access to macOS Contacts (CNContactStore) and mapping to the existing PersonIngestRecord/gateway schema.
- Implement batching and backoff to POST to Gateway `/catalog/contacts/ingest` (support simulate mode for CI).
- Add option to run in `simulate` mode (no FDA required), and a `limit` parameter for testing.
- Handle photo hashing (SHA256) and label localization (reusing `localizedStringForLabel:` like the Python version).
- Add robust error handling and state persistence to `~/.haven/contacts_collector_state.json`.
- Add unit tests and fixtures (small set of representative contacts) and update `hostagent/QUICKSTART.md` and `AGENTS.md` with the new endpoints.

Acceptance Criteria:
- `POST /v1/collectors/contacts:run` returns valid JSON with `status` and `people` when run in simulate mode.
- Hostagent can run mount-based collection with FDA when run locally and return full person records matching current Python collector schema.
- Batching to Gateway works and respects `CONTACTS_BATCH_SIZE` env var; use backoff/retries on transient HTTP errors.
- Unit tests exercise parsing logic and photo hash computation.

Notes:
- The script `scripts/collectors/collector_contacts.py` is attached in the issue for reference.
- Label this task `service/hostagent`, `type/task`, `risk/med`.

```
---

### haven-24 - HostAgent: Make collector polling intervals configurable (iMessage, LocalFS, Contacts)

Status: **open**

Priority: **2**

Labels: contacts_collector, imessage_collector, localfs_collector, mail_collector, notes_collector, task_collector

```md
Add configuration and runtime controls to set polling intervals for HostAgent collectors (iMessage, LocalFS, Contacts, and any future collectors).\n\nBackground:\nHostAgent currently runs collectors on fixed schedules. Operators need the ability to tune polling frequency per-collector to balance CPU/IO, battery, and timeliness. This task adds config, runtime endpoints, and documentation.\n\nAcceptance criteria:\n- Add per-collector polling interval configuration via: 1) `hostagent.yaml` config file (per-collector keys), 2) environment variables `HOSTAGENT_<COLLECTOR>_POLL_INTERVAL_SEC`, and 3) CLI flags for simulate/test runs.\n- Implement runtime endpoints: `GET /v1/collectors/{collector}/poll_interval` and `POST /v1/collectors/{collector}/poll_interval` to view and update the interval without restart. POST accepts `{ "interval_seconds": <number> }` and validates min/max bounds.\n- Ensure iMessage, LocalFS, and Contacts collectors read the effective interval and apply it for scheduling/backoff; new collectors should reuse the same scheduling helper.\n- Validate that changes via environment, config file, and runtime API follow this precedence: API update > env var > config file > default (60s). Document this precedence in `AGENTS.md` and `hostagent/QUICKSTART.md`.
- Add unit tests for scheduling helper and integration tests that simulate changing the poll interval at runtime and confirm the collector respects the new interval within one cycle.
- Add labels: `service/hostagent`, `type/task`, `risk/low`, `priority:P2`.
\nNotes:\n- Use sensible min/max (min 5s, max 86400s = 1 day) and defensive validation.\n- Prefer a small, shared scheduling utility that emits schedule ticks and supports update at runtime and backoff.\n- Keep changes backwards compatible; default behavior remains current schedule if no config provided.\n
```
---

### haven-25 - Local Email Collector: Mail.app cache integration (Epic)

Status: **open**

Priority: **1**

Labels: mail_collector

```md
Enable ingestion of high-signal, actionable emails from the Mail.app local cache into Haven, preserving privacy and running on-device.

Core goals:
- Parse macOS Mail.app local cache (~/Library/Mail/V*/) in two modes: Indexed (Envelope Index SQLite) and Crawler (.emlx files + FSEvents).
- Incremental sync using (ROWID, inode, mtime) and avoid reprocessing.
- Noise filtering for Junk/Trash/Promotions, adaptive per-sender suppression, VIP handling, and list-unsubscribe heuristics.
- Intent classification (bills, receipts, confirmations, appointments, action requests, notifications) with entity extraction (dates, amounts, orgs, confirmation numbers).
- Link resolver integration (Swift WKWebView CLI) to dereference "View Online" links and fetch rendered text/PDFs.
- Attachment handling: dedup by SHA256, upload to MinIO via Gateway, and trigger standard extraction.
- Privacy defaults: no external network calls, local model inference (Ollama), redaction of PII before embeddings, summary-only outbound payloads.

Deliverables:
- services/collector/collector_email_local.py: host collector that reads Mail cache and posts v2 document payloads via Gateway (/v1/ingest or /v1/ingest/file).
- hostagent/Sources/LinkResolver Swift CLI: WKWebView-based dereferencer for link targets and PDF capture.
- tests/test_collector_email_local.py: unit and integration tests for parsing, deduplication, filtering, and ingestion.
- compose.yaml profile entry to register the new collector.
- Postgres schema migration to add `intent` and `relevance_score` fields to the documents/chunks schema.

Constraints & Security:
- Read-only access to Mail cache; require Full Disk Access in production launchd context.
- Do not make outbound network calls during extraction; models run locally where possible.
- Respect user privacy: redact emails, addresses, account numbers from text sent to downstream services and embeddings.

Acceptance criteria:
1. Collector runs in both Indexed and Crawler modes and produces v2 document payloads matching Gateway contract with `source_type="email_local"`.
2. Incremental sync correctly detects new/modified messages and avoids duplicates (idempotency key behavior verified).
3. Noise filtering reduces spam/promotional messages (tests show reduced false positives against sample mailboxes).
4. Link Resolver CLI accepts a URL and returns rendered text or a PDF blob metadata; test harnessable via HostAgent endpoint.
5. Attachments are hashed, uploaded via Gateway to MinIO, and referenced in the document payload.
6. Tests cover parsing, entity extraction (dates, amounts, orgs), and privacy redaction rules.

Notes and next steps:
- Start with a prototype collector that reads Envelope Index for delta sync; fall back to crawler mode if DB missing or inaccessible.
- Keep LinkResolver as an optional HostAgent helper; collector should work without it but will include link targets when available.
- Consider adaptive noise model later (collect per-sender stats) — implement as follow-up task.

```
---

### haven-28 - Swift CLI: LinkResolver for email "View Online" links

Status: **open**

Priority: **2**

Labels: mail_collector

```md
Create Swift CLI tool to resolve "View Online" links and download PDFs from HTML emails.

**Architecture:**
- Standalone Swift CLI: `hostagent/Sources/LinkResolver/main.swift`
- Uses WKWebView to render JavaScript-heavy email links
- Downloads PDFs when link points to document
- Returns JSON with rendered text or PDF metadata

**Input (stdin or argv):**
```json
{
  "url": "https://example.com/view-online/12345",
  "timeout_seconds": 30
}
```

**Output (stdout):**
```json
{
  "url": "https://...",
  "status": "success",
  "content_type": "text/html",
  "text": "rendered text...",
  "pdf_path": "/tmp/downloaded.pdf",
  "error": null
}
```

**Integration options:**
1. Callable as standalone binary: `linkresolver < input.json`
2. Optionally exposed via HostAgent endpoint: `POST /v1/linkresolver`

**Testing:**
- Unit tests with mock WKWebView
- Integration tests with real URLs
- Timeout handling
- Error cases (404, SSL errors, etc.)

**Acceptance:**
- CLI tool builds and runs standalone
- Successfully renders JavaScript-heavy pages
- Downloads PDFs and returns metadata
- Error handling for network failures
- Optional HostAgent endpoint integration documented
```
---

### haven-30 - Collector: Indexed Mode (Envelope Index SQLite)

Status: **open**

Priority: **1**

Labels: mail_collector

```md
Implement Indexed Mode: read Envelope Index SQLite database for delta sync.

**Location:** `scripts/collectors/collector_email_local.py` (Indexed mode functions)

**Key functions:**
1. `locate_envelope_index() -> Optional[Path]`
   - Search for Envelope Index database in Mail.app cache
   - Return path or None if not found

2. `read_envelope_index(db_path: Path, last_rowid: int) -> List[EmailMetadata]`
   - Query messages with ROWID > last_rowid
   - Extract subject, sender, date, mailbox, flags
   - Return list of email metadata

3. `filter_mailboxes(emails: List[EmailMetadata]) -> List[EmailMetadata]`
   - Skip Junk, Trash, Promotions
   - Honor VIP status

4. `resolve_emlx_paths(metadata: List[EmailMetadata]) -> List[Tuple[EmailMetadata, Path]]`
   - Map Envelope Index records to .emlx file paths
   - Handle missing files gracefully

**State tracking:**
- Store last seen ROWID in `~/.haven/email_collector_state.json`
- Track `(ROWID, inode, mtime)` for change detection

**Testing:**
- Mock Envelope Index database
- Verify incremental sync behavior
- Test mailbox filtering logic

**Acceptance:**
- Successfully queries Envelope Index
- Incremental sync works correctly (no duplicates, no missed messages)
- Gracefully falls back to Crawler mode if DB unavailable
```
---

### haven-31 - Collector: Crawler Mode (.emlx file scanning)

Status: **open**

Priority: **1**

Labels: mail_collector

```md
Implement Crawler Mode: scan .emlx files with FSEvents tracking as fallback.

**Location:** `scripts/collectors/collector_email_local.py` (Crawler mode functions)

**Key functions:**
1. `scan_mail_directories() -> List[Path]`
   - Walk `~/Library/Mail/V*/mailboxes/`
   - Find all .emlx files
   - Skip Junk/Trash/Promotions directories

2. `track_file_state(path: Path, state: Dict) -> bool`
   - Check `(inode, mtime)` against stored state
   - Return True if file is new or changed

3. `batch_emlx_files(paths: List[Path], batch_size: int) -> Iterable[List[Path]]`
   - Group files for processing
   - Yield batches to avoid memory issues

4. `setup_fsevents_watcher() -> Optional[FSEventsWatcher]`
   - Monitor Mail.app directories for changes
   - Queue new/modified .emlx files for processing

**State tracking:**
- Store `{path: {inode, mtime, last_processed}}` in state file
- Periodic full scans to catch missed events

**Performance:**
- Only process changed files
- Use FSEvents to avoid polling
- Batch processing to limit memory usage

**Testing:**
- Mock filesystem with sample .emlx files
- Verify state tracking prevents reprocessing
- Test FSEvents integration

**Acceptance:**
- Crawler mode finds all .emlx files
- Incremental processing works (no duplicates)
- FSEvents watcher detects new messages in real-time
- Performance acceptable for large mailboxes (10k+ messages)
```
---

### haven-32 - Collector: Image enrichment for email attachments

Status: **open**

Priority: **1**

Labels: mail_collector

```md
Implement image enrichment pipeline for email attachments before upload.

**Location:** `scripts/collectors/collector_email_local.py` (enrichment functions)

**Integration with existing patterns:**
- Use `shared.image_enrichment.enrich_image()` for OCR, entities, captions
- Match pattern from `collector_imessage.py` and `collector_localfs.py`
- Cache results in `~/.haven/email_image_cache.json`

**Key functions:**
1. `enrich_email_image(attachment_path: Path, cache: ImageEnrichmentCache) -> Optional[Dict]`
   - Load image from Mail.app attachments directory
   - Call `enrich_image()` with cache
   - Return OCR text, entities (dates, amounts, orgs), caption

2. `build_attachment_payload(enrichment: Dict, metadata: Dict) -> Dict`
   - Combine file metadata with enrichment data
   - Structure for Gateway `/v1/ingest/file` upload

3. `process_email_attachments(email: EmailMessage, cache: ImageEnrichmentCache) -> List[Dict]`
   - Extract all attachments from email
   - Enrich images before upload
   - Return list of attachment payloads

**HostAgent integration:**
- OCR via HostAgent `/v1/ocr` endpoint (macOS Vision)
- Entity extraction from OCR text
- Caption via Ollama (if enabled)

**Testing:**
- Mock HostAgent OCR endpoint
- Test with sample email attachments (receipts, bills, photos)
- Verify caching prevents reprocessing
- Test enrichment failure handling

**Acceptance:**
- Image attachments enriched with OCR, entities, and captions
- Results cached and reused on re-ingestion
- Follows same pattern as iMessage/LocalFS collectors
- Gracefully handles enrichment failures (still uploads file)
```
---

### haven-33 - Collector: Gateway payload construction and submission

Status: **open**

Priority: **1**

```md
Build Gateway ingestion payloads and handle file/text submission.

**Location:** `scripts/collectors/collector_email_local.py` (ingestion functions)

**Key functions:**
1. `build_document_payload(email: EmailMessage, intent: Dict, relevance: float) -> Dict`
   - Construct v2 document payload for Gateway `/v1/ingest`
   - Include redacted text, people, metadata
   - Set `source_type="email_local"`
   - Add `intent` and `relevance_score` fields

2. `build_thread_payload(email: EmailMessage) -> Dict`
   - Extract In-Reply-To and References headers
   - Build thread_id from Message-ID lineage
   - Identify participants (sender, recipients)

3. `submit_email_document(payload: Dict, session: requests.Session) -> Dict`
   - POST to Gateway `/v1/ingest`
   - Handle idempotency (duplicate detection)
   - Return submission response

4. `submit_email_attachment(file_path: Path, enrichment: Dict, session: requests.Session) -> Dict`
   - Upload via Gateway `/v1/ingest/file`
   - Include enrichment metadata (OCR, entities, caption)
   - Handle SHA256 deduplication

**Idempotency:**
- Use `email:{message_id}:{content_hash}` as idempotency key
- Gateway deduplicates based on key

**Error handling:**
- Retry transient failures (429, 503)
- Log permanent failures (4xx) without retry
- Continue processing batch on single failure

**Testing:**
- Mock Gateway endpoints
- Verify payload structure matches v2 schema
- Test idempotency behavior
- Test error handling and retries

**Acceptance:**
- Successfully submits emails to Gateway
- Idempotency prevents duplicate ingestion
- Attachments uploaded with enrichment metadata
- Error handling allows batch to continue
```
---

### haven-34 - Collector: Main entry point and orchestration

Status: **open**

Priority: **1**

```md
Assemble main collector entry point with CLI, state management, and orchestration.

**Location:** `scripts/collectors/collector_email_local.py` (main collector class)

**Architecture:**
```python
class EmailCollectorConfig:
    # Config from env vars and CLI args
    mode: str  # "indexed" or "crawler"
    poll_interval: float
    batch_size: int
    gateway_url: str
    auth_token: str
    state_file: Path
    image_cache_file: Path
    linkresolver_enabled: bool

class EmailCollectorState:
    # Persistent state management
    last_rowid: int  # For Indexed mode
    file_states: Dict[str, Dict]  # For Crawler mode
    
class EmailLocalCollector:
    def run(self):
        # Main loop: poll → fetch → parse → enrich → submit
```

**Main loop:**
1. Determine mode (Indexed if Envelope Index exists, else Crawler)
2. Fetch new emails (via Indexed or Crawler mode)
3. Filter noise emails
4. Parse and extract text
5. Enrich image attachments
6. Classify intent and relevance
7. Build payloads and submit to Gateway
8. Update state

**CLI:**
```bash
python -m scripts.collectors.collector_email_local \
  --mode auto \
  --poll-interval 30 \
  --batch-size 50 \
  --one-shot
```

**State persistence:**
- Save after each batch
- Atomic writes with temp file + rename

**Testing:**
- End-to-end test with mock Mail.app cache
- Verify both Indexed and Crawler modes work
- Test state recovery after crash

**Acceptance:**
- Collector runs in continuous or one-shot mode
- Automatically selects Indexed or Crawler mode
- State persists correctly between runs
- Logs structured output for observability
- CLI matches patterns from other collectors
```
---

### haven-35 - Tests: Comprehensive email collector test suite

Status: **open**

Priority: **1**

Labels: email_collector, mail_collector

```md
Create comprehensive test suite for email collector.

**Location:** `tests/test_collector_email_local.py`

**Test categories:**

1. **Unit tests:**
   - `.emlx parsing` (valid, malformed, multipart)
   - `Intent classification` (bills, receipts, appointments)
   - `Noise filtering` (promotional, List-Unsubscribe)
   - `PII redaction` (emails, phones, account numbers)
   - `Attachment path resolution`

2. **Integration tests:**
   - `Indexed mode` with mock Envelope Index DB
   - `Crawler mode` with mock filesystem
   - `Image enrichment` with mock HostAgent
   - `Gateway submission` with mock endpoints
   - `State persistence` and recovery

3. **End-to-end tests:**
   - Full ingestion pipeline (email → enrichment → Gateway → Catalog)
   - Idempotency (re-running same emails)
   - Error recovery (partial batch failure)

**Fixtures:**
- Sample .emlx files (various types: bills, receipts, newsletters)
- Mock Envelope Index database
- Mock HostAgent responses
- Mock Gateway responses

**Coverage targets:**
- >80% line coverage
- All error paths tested
- Edge cases documented

**Acceptance:**
- All tests pass
- Tests cover both Indexed and Crawler modes
- Image enrichment pipeline tested
- Privacy/PII redaction verified
- Performance benchmarks for large mailboxes
```
---

### haven-36 - Docs: Email collector setup and operational guide

Status: **open**

Priority: **2**

Labels: mail_collector

```md
Document setup, configuration, and operational runbook for email collector.

**Deliverables:**

1. **README section** (update main README.md):
   - Prerequisites (Full Disk Access for Mail.app)
   - Installation steps
   - Environment variables
   - Running the collector (one-shot and daemon modes)

2. **Configuration guide** (`documentation/email_collector_setup.md`):
   - Mail.app cache location discovery
   - Envelope Index vs Crawler mode selection
   - LinkResolver integration (optional)
   - Image enrichment settings (Ollama, HostAgent)
   - Noise filtering configuration

3. **Operational runbook:**
   - Health check commands
   - State file inspection
   - Troubleshooting common issues
   - Performance tuning (batch size, poll interval)
   - Monitoring and observability

4. **Privacy and security notes:**
   - Full Disk Access requirements
   - PII redaction behavior
   - Data residency (what stays local vs uploaded)
   - LaunchAgent setup for auto-start

**Compose.yaml notes:**
- No Docker service needed (runs on host)
- Document env vars for reference

**Acceptance:**
- Documentation covers all setup steps
- Runbook addresses common failure modes
- Security/privacy implications clearly stated
- Matches style/format of existing collector docs
```
---

### haven-37 - Integration: End-to-end validation with live Mail.app data

Status: **open**

Priority: **1**

Labels: email_collector, mail_collector

```md
Validate end-to-end integration with live Mail.app data (manual testing phase).

**Goals:**
- Run collector against real Mail.app cache
- Verify Indexed mode works with live Envelope Index
- Test Crawler mode with actual .emlx files
- Validate image enrichment with real email attachments
- Confirm Gateway ingestion and search indexing

**Test scenarios:**
1. **Initial sync:**
   - Run collector on mailbox with 100+ messages
   - Verify all messages ingested without errors
   - Check for duplicates in Catalog

2. **Incremental sync:**
   - Receive new emails
   - Run collector again
   - Confirm only new messages processed

3. **Attachment handling:**
   - Process emails with image attachments
   - Verify OCR, entity extraction, captions
   - Confirm upload to MinIO

4. **Intent classification:**
   - Manually verify bills/receipts detected correctly
   - Check relevance scoring for noise filtering

5. **Search validation:**
   - Query Gateway `/v1/search` for specific email content
   - Verify semantic search finds relevant emails
   - Test faceted search by intent

**Metrics to collect:**
- Processing time per email
- Image enrichment latency
- Gateway API latency
- Memory usage during large batches

**Acceptance:**
- Successfully processes real mailbox (1000+ messages)
- No data loss or corruption
- Image enrichment works on real attachments
- Search returns relevant results
- Performance acceptable for daily use
```
---

### haven-39 - Research: Mail.app cache structure and .emlx format

Status: **open**

Priority: **2**

Labels: mail_collector

```md
Research and document the Mail.app local cache structure to inform collector implementation.

**Goals:**
- Identify the location and structure of Mail.app cache directories (`~/Library/Mail/V*/`)
- Document the Envelope Index SQLite database schema (tables, columns, indexes)
- Understand the .emlx file format (RFC 2822 + plist metadata)
- Map attachment storage paths and how they link to messages
- Identify which mailboxes/folders to filter (Junk, Trash, Promotions)
- Document VIP flags and List-Unsubscribe headers location

**Deliverables:**
- Technical notes in `documentation/mail_app_cache_structure.md`
- Sample queries for Envelope Index database
- .emlx parsing pseudo-code
- Attachment path resolution logic

**Acceptance:**
- Documentation covers both Indexed and Crawler mode requirements
- Includes concrete file paths and SQLite queries
- Identifies all metadata fields needed for noise filtering
```
---

### haven-40 - Publish Docs with MkDocs + Material

Status: **open**

Priority: **1**

```md
## Summary

Create a first-class documentation system for Haven by introducing a `/docs/` folder and publishing a static site using **MkDocs** with the **Material** theme. Wire in an **API documentation section** that renders the project’s OpenAPI spec as an interactive reference.

## Goals

Centralize product, architecture, and operations docs under `/docs/`.
Publish a branded, searchable docs site with a stable URL.
Expose the OpenAPI spec through an interactive UI with deep links and permalinks.
Adopt a “docs as code” workflow with PR reviews.

## Non-Goals

Multi-version docs and i18n in v1.
Automated API client generation.
Custom theming beyond Material configuration.

## Scope

Add `/docs/` as the single source for narrative docs, guides, and runbooks.
Publish to a static host (e.g., GitHub Pages) from `main`.
Include an **API** section that consumes an OpenAPI file from the repo and renders it as a browsable, searchable reference (tags, endpoints, schemas).
Ensure dark/light mode, search, copy-code buttons, admonitions, and mobile navigation.

## Information Architecture (initial)

* `index.md` — Landing and key entry points.
* `getting-started.md` — Quickstart for local preview and contributions.
* `architecture/overview.md` — System context, key services, data flow.
* `architecture/services.md` — Gateway, Catalog, Search, Embedding, Postgres, Qdrant, MinIO.
* `operations/local-dev.md` — Local development environment basics.
* `operations/deploy.md` — High-level deploy overview.
* `contributing.md` — Authoring standards and review process.
* `changelog.md` — Human-readable highlights.
* `api/` — **OpenAPI documentation site** (see next section).

## OpenAPI Documentation Wiring

The site must surface the project’s OpenAPI spec (e.g., `/openapi/openapi.yaml` or `/openapi/openapi.json`) as an interactive API reference under `/api/`.
The API page must provide: tag navigation; operation details with request/response schemas; schema/model browsing; server/endpoint selection if defined; and stable deep links to operations and schemas.
The API reference must be generated at build time from the spec in the repo, so PRs that change the spec update the published reference automatically.
If multiple specs exist (e.g., `gateway`, `catalog`), the `/api/` section must list and route to each spec clearly (e.g., `/api/gateway/`, `/api/catalog/`).
A “Download spec” link must be present for each exposed spec.
Document the canonical spec locations (e.g., `/openapi/gateway.yaml`, `/openapi/catalog.yaml`) and require that they remain valid for the build.

## Deliverables

A live docs site reachable at a stable URL.
`/docs/` folder populated with the IA above.
`mkdocs.yml` configured for Material theme, repo links, navigation, and search.
An `/api/` section that renders the OpenAPI spec(s) from the repo with interactive exploration and deep linking.
A “Documentation” section in `README` that links to the site and explains how to preview docs locally and contribute via PRs.

## Acceptance Criteria

Visiting the site root shows the Material-styled landing page and working search.
Dark/light mode works, code blocks have copy buttons, and admonitions render correctly.
The `/api/` section loads the OpenAPI reference from the repo and supports tag filtering, operation details, schema browsing, and deep links that remain stable after rebuilds.
Changes to `/docs/**`, `mkdocs.yml`, or `/openapi/**` result in an updated published site.
The API page(s) display a visible “Download spec” link that returns the exact spec version used to render the page.

## Dependencies

An OpenAPI spec committed to the repo in a stable path.
Static hosting for the generated site and a CI workflow that publishes on merge to `main`.

## Risks

Spec drift or invalid OpenAPI will break the API page; mitigate with CI validation of the spec.
Docs rot if authoring standards are unclear; mitigate with contributor guidance and PR templates.

## Definition of Done

Docs site is live at the chosen URL with the IA above.
OpenAPI reference is interactive, up to date, and reachable at `/api/`.
README links to the site and explains how to preview and contribute.

## Takeaways

This establishes a durable “docs as code” foundation with strong UX and a first-class API reference tied to the repo’s source of truth.

## Next Steps

Confirm canonical OpenAPI file paths and names.
Adopt the IA and stub pages.
Enable CI publish of the site and spec-driven API reference.
```
---

### haven-45 - README & Contributing: document docs preview and contribution process

Status: **open**

Priority: **3**

```md
Update `README.md` with a "Documentation" section linking to the published docs and document how to preview the site locally and contribute docs via PRs. Include:

- How to run locally (`pip install -r local_requirements.txt` + `mkdocs serve`)
- How to add API spec changes and their CI validation
- PR checklist for documentation changes

Acceptance criteria:
- `README.md` contains Documentation section and contribution instructions
- PR template or checklist exists (can be a short file under `.github/ISSUE_TEMPLATE` or `docs/`)

Labels: ["type/task","service/docs","risk/low","size/S"]
```
---

### haven-46 - HostAgent: iMessage collector run should return earliest/latest message timestamps

Status: **open**

Priority: **2**

Labels: imessage_collector

```md
When the HostAgent iMessage collector runs (collector endpoint or CLI), the response should include metadata fields `earliest_touched_message_timestamp` and `latest_touched_message_timestamp` indicating the earliest and latest message timestamps touched by that run.

Acceptance criteria:
- A beads task describing the change and location to implement.
- Response from the hostagent collector run includes the two timestamp fields (ISO 8601 UTC or unix ms).
- Tests or notes referencing `hostagent/Sources/HostHTTP/Handlers/HealthHandler.swift` and the iMessage collector implementation files.

Suggested files to update:
- `hostagent/Sources/HostHTTP/Handlers/ImessageCollectorHandler.swift` (or similar collector file)
- `hostagent/Sources/HostHTTP/Handlers/HealthHandler.swift` (if health or run endpoints are involved)
- Add/update tests under `tests/` to assert the metadata is present.

Priority: P2
Size: S
Labels: ["service/hostagent","type/task","domain/collectors","risk/low"]
```
---

### haven-47 - HostAgent: persist iMessage collector state to avoid re-submits and support backfill

Status: **open**

Priority: **2**

Labels: imessage_collector

```md
Persist HostAgent iMessage collector state similar to the Python collector to provide robust resume, backfill, and error tracking capabilities.

Outcome / Acceptance criteria:
- HostAgent persists collector state (a small JSON state file in `~/.haven/hostagent_state.json` or similar) mirroring Python `CollectorState` semantics: track `last_seen_rowid` (high-water mark), `max_seen_rowid`, `min_seen_rowid`, `initial_backlog_complete`, plus optionally `failed_submissions` and retry metadata.
- On run, HostAgent consults this persisted state to avoid re-submitting messages that have already been successfully posted and acknowledged by the Gateway/Catalog (use event version signatures + idempotency_key to confirm success).
- Collector run responses include state information: `last_seen_rowid`, `min_seen_rowid`, `max_seen_rowid`, `earliest_touched_message_timestamp`, `latest_touched_message_timestamp`, and a summary of `failed_submissions` with reasons (if any).
- Provide an endpoint or API response fields enabling reprocessing of failed submissions (e.g., return sufficient metadata to re-run or allow a retry endpoint to re-emit saved failed events).
- Persist failed submissions (with `idempotency_key`, `document_id`, `error`, `attempt_count`, `last_attempt_at`) for later reprocessing. Provide a sweep/retry strategy (exponential backoff or manual retry) and tests or scripts demonstrating reprocessing.
- Add unit/integration tests (or test harnesses) to validate: state persistence, resume behavior (no duplicate sends), backfill from earliest timestamp, and failed submission collection & retry.

Suggested files to update/implement:
- `hostagent/Sources/HostHTTP/Handlers/IMessageHandler.swift` (core logic: read/write state, compute earliest/latest timestamps, include in run response)
- `hostagent/Sources/HostAgent/CollectorState.swift` (new Swift model to mirror Python CollectorState and failed submission records)
- `hostagent/Tests/` (tests for state tracking and reprocessing behavior)
- Docs: `documentation/` note describing the state file format and operational guidance

Notes:
- Default persistence path: `~/.haven/hostagent_state.json` (configurable via `HavenConfig` if desired).
- For dedupe, rely primarily on Catalog idempotency plus a local version tracker for short-term avoidance of re-sends.
- Keep the feature behind a config flag to make rollout safe.

Priority: P2
Size: M
Labels: ["service/hostagent","feature","collectors","persistence","reliability"]
```
---

### haven-51 - Migrate repository to use uv + single pyproject.toml for env & package management

Status: **open**

Priority: **2**

```md
Background:
The repository currently uses multiple requirement files (`requirements.txt`, `local_requirements.txt`) and per-environment workflows. We want to converge on `uv` (https://uvproject.io/) for environment and package management and a single `pyproject.toml` as the canonical project manifest. This will simplify local development, Docker builds, and CI across the monorepo.

Goals:
- Adopt `uv` for environment management and package installs.
- Consolidate dependencies into a single `pyproject.toml` at repo root.
- Ensure Dockerfile and `compose.yaml` builds use `pyproject.toml` and `uv`.
- Provide documentation and migration notes for maintainers and contributors.

Acceptance criteria:
1. A beads issue exists documenting the migration plan, with clear labels and size.
2. The repo has an entry in docs or `.tmp/migrate-to-uv.md` explaining developer steps to install and use `uv` locally.
3. CI and Docker builds reference `pyproject.toml` and `uv` in at least one CI job or Docker build in a branch or PR (this bead may include follow-up tasks to update CI fully).
4. Existing test suite runs successfully using the new environment on local machine (or documented blockers if any remain).
5. Transition plan lists deprecated files and compat shims for a rollout.

Notes:
- Keep `requirements.txt` as a compatibility shim for Docker/CI until deployment is verified, but note in acceptance criteria when it can be removed.
- Update `AGENTS.md` and `README.md` to mention `uv` where applicable.

Labels: ["service/devops","type/task","risk/med","domain/developer-experience"]
Priority: 2
Size: M
```
---

### haven-52 - Add Google-style docstrings and API docs generation

Status: **open**

Priority: **2**

```md
Add comprehensive Google-style docstrings across all Python files and add configuration/scripts to generate API documentation automatically.

Acceptance criteria:
- All public functions, classes, and modules in `src/`, `services/`, `shared/`, and `scripts/` have Google-style docstrings (summary, args, returns, raises, examples where appropriate).
- A docs generation configuration is added using Sphinx (with napoleon) or MkDocs + mkdocstrings and can produce an API site.
- A small README section describes how to run the docs generation locally (commands) and where generated docs live.
- The bead includes suggested tooling, review checklist, and scope exclusions (tests, __pycache__, vendored code).

Suggested size: M, priority: P1, labels: ["type/task","service/docs","risk/low"].

Notes:
- Recommend using Sphinx with napoleon extension for Google-style docstrings and autodoc, or MkDocs + mkdocstrings for a lighter setup. Include both options in the bead body so maintainers can choose.
- Include script/Makefile targets to run the docs build.

```
---

### haven-53 - MKDocs integration notes for haven-52 (docstrings + mkdocs)

Status: **open**

Priority: **2**

```md
Update to bead haven-52: ensure the docs generation work is incorporated into the repository's existing MkDocs site.

Changes to include in bead body:

1) mkdocs.yml edits
- Add a top-level `nav` entry for `API` (or `Reference`) pointing to `api/index.md`.
- Add `plugins` entries: `- search` and `- mkdocstrings`.
- Example plugin config snippet:

plugins:
  - search
  - mkdocstrings:
      handlers:
        python: {}

2) requirements-docs.txt
- Add the following packages to `requirements-docs.txt`:
  - mkdocs
  - mkdocs-material (optional)
  - mkdocstrings
  - pymdown-extensions
  - mkdocs-autoreload (optional for local dev)

3) docs/api/index.md
- Add an example API page that uses mkdocstrings to document the project:

  ## API Reference

  ::: haven
      handler: python

  This will include the top-level package `haven`. You can also add targeted modules like `haven.shared`, `haven.services.gateway_api`, etc.

4) Build target / script
- Add a small script `scripts/build_docs_api.sh` or a Makefile target `docs-api`:

  #!/usr/bin/env bash
  set -euo pipefail
  pip install -r requirements-docs.txt
  mkdocs build

- Optionally `mkdocs build -d site/` to place output where current `site/` expects.

5) CI notes
- Ensure CI job installs `requirements-docs.txt` and runs `mkdocs build`.

6) Scope & exclusions
- Document that tests, `__pycache__`, and vendor directories are excluded.

Please integrate these details into bead haven-52 so maintainers know exactly what to do and how to validate.

```
---

### haven-54 - HostAgent email collector: crawl .emlx, enrich, and post to Gateway

Status: **open**

Priority: **1**

```md
Implement HostAgent collector to crawl Mail.app .emlx files (crawler mode), parse messages using the EmailService, resolve attachments, run image enrichment (OCR + entity extraction), and emit v2 document payloads to Gateway (/v1/ingest or /v1/ingest/file).

Acceptance criteria:
- HostAgent exposes `POST /v1/collectors/email_local:run` and `GET /v1/collectors/email_local/state` endpoints.
- Collector can run in simulate mode using fixtures (no Full Disk Access required).
- Uses `EmailService.parseEmlxFile` and `EmailService.extractEmailMetadata` for parsing & metadata.
- Resolves attachments via Mail.app cache conventions when available; in simulate mode attachments may be absent.
- Calls `OCR` and `Entity` modules for enrichment when enabled in config.
- Posts v2 document payloads to Gateway with `source_type="email_local"` and includes idempotency keys.
- Unit tests included (fixtures) and swift tests pass locally.

Notes:
- Link to epic: haven-25
- Label: mail_collector
- Priority: P1
- Size: M
```
---

### haven-56 - EmailCrawler: .emlx file discovery and tracking

Status: **open**

Priority: **1**

```md
Implement crawler to discover and track .emlx files in Mail.app cache or simulate directory.

**Implementation:**
- Create `hostagent/Sources/Email/EmailCrawler.swift`
- Scan directory tree for `.emlx` files
- Track processing state (filepath, inode, mtime, processed flag)
- Support incremental crawling (skip already-processed files)
- Handle simulate mode (fixtures directory) vs. real mode (`~/Library/Mail/V*/`)
- Return batch of unprocessed files up to limit

**State persistence:**
- In-memory only for now (persistent state in follow-up)
- Track last scan time and file metadata

**Testing:**
- Unit tests with fixture directory
- Test incremental behavior (skip processed files)
- Test file filtering (only .emlx)

**Acceptance:**
- Crawler discovers .emlx files in directory tree
- Returns unprocessed files for batch processing
- Simulate mode works with test fixtures
```
---

### haven-57 - EmailAttachmentResolver: locate and hash attachment files

Status: **open**

Priority: **2**

```md
Implement attachment resolution for Mail.app cache structure.

**Implementation:**
- Extend `EmailService` or create helper to resolve attachment filesystem paths
- Follow Mail.app conventions: `~/Library/Mail/V*/Data/Messages/Attachments/<mailbox>/<message>/<part>/<filename>`
- Hash attachment files (SHA256) for deduplication
- Return attachment metadata: path, SHA256, size, MIME type

**Fallback behavior:**
- In simulate mode or if attachment not found, return metadata with path=nil
- Log warnings for missing attachments but don't fail

**Testing:**
- Unit tests with mock attachment directory structure
- Test SHA256 hashing
- Test missing attachment handling

**Acceptance:**
- Resolves attachment paths when available
- Computes SHA256 hash for found files
- Gracefully handles missing attachments
```
---

### haven-58 - EmailLocalHandler: Gateway integration and enrichment pipeline

Status: **open**

Priority: **1**

```md
Wire up parsing, enrichment, and Gateway posting in EmailLocalHandler.

**Implementation:**
- Use `EmailCrawler` to get batch of .emlx files
- For each file:
  1. Parse with `EmailService.parseEmlxFile`
  2. Extract metadata with `EmailService.extractEmailMetadata`
  3. Resolve attachments (if present)
  4. For image attachments: call OCR and Entity modules if enabled
  5. Build v2 document payload with `source_type=\"email_local\"`
  6. Generate idempotency key (hash of message-id + path)
  7. POST to Gateway `/v1/ingest`
  8. For attachments: POST to Gateway `/v1/ingest/file` with SHA256 and metadata
- Track stats: messages processed, documents created, errors
- Handle errors gracefully (log and continue)

**Configuration:**
- Respect `config.modules.mail.enabled`
- Respect `config.modules.ocr.enabled` and `config.modules.entity.enabled`

**Testing:**
- Integration test with fixtures and mock Gateway
- Test enrichment pipeline (OCR + entity)
- Test error handling (malformed .emlx, Gateway failures)

**Acceptance:**
- End-to-end: .emlx → parse → enrich → Gateway POST
- Idempotency keys prevent duplicates
- Stats accurately reflect processing
- Tests pass with fixtures
```
---

### haven-59 - HostAgent mail filters test fixtures fail to load

Status: **open**

Priority: **2**

```md
Running `swift test` currently fails in `MailFiltersTests` because the YAML and JSON fixtures created on the fly are rejected by `MailFiltersLoader`. The suite reports assertion failures (expected include/exclude flags) and an `unsupportedFormat("Unable to parse filters from …yaml")` error when the loader reads temporary files. The failure is reproducible with `swift test --filter MailFiltersTests` and was observed while finishing haven-55.

Tasks:
- Investigate the filter loader to ensure it accepts the serialized fixture format produced by the tests (likely missing schema/version headers or requiring stricter detection).
- Adjust the loader or the fixture generator so inline JSON/YAML filters round-trip during tests.
- Update tests/fixtures accordingly and re-enable full `swift test` runs.

Acceptance:
- `swift test --filter MailFiltersTests` passes locally.
- Full `swift test` completes without MailFilters-related failures.

Notes:
- The failing tests are:
  * `MailFiltersTests.testDSLParsingAndEvaluation`
  * `MailFiltersTests.testEnvironmentJSONFilter`
  * `MailFiltersTests.testAttachmentMimePredicate`
  * `MailFiltersTests.testYAMLFileLoadingAndPrefilterMerge`
- Error example: `unsupportedFormat("Unable to parse filters from /var/folders/.../temp.yaml")`
```
---

