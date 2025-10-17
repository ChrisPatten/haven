# IMPLEMENTATION_PLAN.md

## Overview

The **HostAgent** is a macOS-native daemon written in Swift that exposes a local API to manage system-level integrations for the Haven platform. It replaces the legacy `imdesc` tool, consolidating macOS-native functionality under a single extensible host service.

### Core Objectives

* Provide a persistent, extensible macOS service for local collection and enrichment tasks.
* Expose a lightweight HTTP API on `localhost` for use by Dockerized Haven services.
* Modularize native components such as:

  * Vision-based OCR and entity detection
  * Face detection (future)
  * Contacts and Mail framework access (future)
  * Filesystem watchers for local ingestion directories
* Maintain feature parity with and eventual replacement of `imdesc.swift`.

### High-Level Architecture

**Daemon Structure**

* Runs as a background process on macOS.
* Listens on a configurable local port (default: `localhost:8089`).
* Uses Swift Concurrency for async task handling.
* Employs modular command routing for OCR, metadata extraction, and control operations.

**Modules**

| Module              | Function                                                           |
| ------------------- | ------------------------------------------------------------------ |
| `OCRModule`         | Performs OCR and text extraction using the macOS Vision framework. |
| `EntityModule`      | Extracts named entities and metadata from OCR text results.        |
| `FaceModule`        | Detects faces for tagging (future stub).                           |
| `ContactsModule`    | Provides access to system Contacts (future stub).                  |
| `FileWatcherModule` | Monitors configured directories for changes (future stub).         |
| `APIServer`         | Exposes REST endpoints for all enabled modules.                    |
| `Settings`          | Defines configuration (port, enabled modules, timeout, etc.).      |

### Interaction Model

```
Docker Collector (Python) → localhost:8089 → HostAgent → Vision/OCR → JSON → Collector → Gateway
```

The HostAgent operates as a **local service boundary** — no cloud calls, no external network exposure.
It receives HTTP requests from the Haven stack (running inside Docker), executes native tasks, and returns structured results.

---

## Phase 1 – Foundation and OCR Capability (Complete)

### Completed Deliverables

* Created initial Swift daemon scaffolding with modular service architecture.
* Implemented local HTTP server with async SwiftNIO.
* Integrated macOS **Vision framework** for OCR (text and entities).
* Established standardized JSON response format compatible with Haven Python collectors.
* Implemented timeout and error handling for external callers.
* Validated end-to-end OCR flow with test images from the iMessage collector.

### Technical Components

* **Swift Packages**

  * `Vision`, `Foundation`, `Dispatch`, `SwiftNIO`
* **Build Artifacts**

  * `hostagent` binary produced by `swift build --configuration release`
* **Build Script**

  * `scripts/build-hostagent.sh` (mirrors `build-imdesc.sh` pattern)
* **Invocation Example**

  ```bash
  ./hostagent serve --port 8089 --enable ocr
  ```
* **API Endpoint Example**

  ```
  POST /ocr
  Body: { "image_path": "/Users/me/Desktop/test.jpg" }
  Response: { "text": "...", "entities": [...], "confidence": 0.97 }
  ```

---

## Phase 2 – Modularization and Configuration

### Goals

* Define modular structure for new native capabilities.
* Create configuration file system for controlling modules and service behavior.
* Implement lifecycle management for starting, stopping, and enabling modules.

### Implementation Tasks

1. **Module Abstraction Layer**

   * Protocol `HostAgentModule` with lifecycle hooks (`start()`, `stop()`, `handle(request:)`).
   * Register available modules in a central registry.

2. **Configuration Management**

   * Read from `/Users/<user>/.haven/hostagent.json`.
   * Support live reload of config via SIGHUP or API call `/reload`.

3. **Logging**

   * Structured logging to `~/.haven/logs/hostagent.log`.
   * Include timestamps, log levels, and error diagnostics.

4. **System Integration**

   * Support `launchd` plist for auto-start on macOS boot.

---

## Phase 3 – Extended Capabilities (Planned)

Phase 3 extends HostAgent with native macOS capabilities beyond basic OCR. Each unit below can be implemented independently.

---

### Unit 3.1 – Enhanced OCR with Layout and Language Detection

**Objective:** Extend the existing OCR module to return richer metadata about detected text, including spatial layout, language detection, and configurable accuracy profiles.

**Technical Approach:**

* Use `VNRecognizeTextRequest` with enhanced observation handling.
* Extract bounding box coordinates for each text block.
* Use `VNRecognizeTextRequestRevision3` for language detection.
* Add configuration parameters for recognition level (`fast` vs `accurate`).

**Implementation Tasks:**

1. **Extend OCR Response Schema**
   * Add `regions` array containing:
     * `text`: String content
     * `bounding_box`: `{x, y, width, height}` normalized coordinates
     * `confidence`: Float confidence score
     * `detected_language`: Optional language code (e.g., `en`, `es`, `zh`)
   * Maintain backward compatibility with existing simple text response.

2. **Add Recognition Level Configuration**
   * Support `recognitionLevel` parameter: `.fast` or `.accurate`
   * Read from config file or accept as request parameter
   * Default to `.fast` for performance

3. **Implement Language Detection**
   * Enable `automaticallyDetectsLanguage` on `VNRecognizeTextRequest`
   * Extract top detected language from observation candidates
   * Return array of detected languages with confidence scores

4. **Update OCR Handler**
   * Modify `OCRModule.swift` to parse bounding boxes from `VNRecognizedTextObservation`
   * Convert Vision coordinate system (bottom-left origin) to standard top-left
   * Add timeout protection for large images

**API Example:**

```json
POST /ocr
{
  "image_path": "/path/to/image.jpg",
  "recognition_level": "accurate",
  "include_layout": true
}

Response:
{
  "status": "success",
  "data": {
    "text": "Schedule plumber Monday 9am",
    "regions": [
      {
        "text": "Schedule plumber",
        "bounding_box": {"x": 0.1, "y": 0.2, "width": 0.4, "height": 0.05},
        "confidence": 0.98,
        "detected_language": "en"
      },
      {
        "text": "Monday 9am",
        "bounding_box": {"x": 0.1, "y": 0.26, "width": 0.3, "height": 0.04},
        "confidence": 0.95,
        "detected_language": "en"
      }
    ],
    "detected_languages": ["en"],
    "recognition_level": "accurate"
  }
}
```

**Testing:**

* Test with multi-language documents
* Validate bounding box coordinates with visual overlay
* Benchmark performance difference between fast/accurate modes

**Estimated Complexity:** Medium (3-4 hours)

---

### Unit 3.2 – Natural Language Entity Extraction Module

**Objective:** Create a standalone module that uses Apple's Natural Language framework to extract named entities (people, places, organizations, dates) from text.

**Technical Approach:**

* Use `NLTagger` with `.nameType` and `.nameTypeOrLexicalClass` schemes
* Support both direct text input and post-OCR pipeline integration
* Return structured entity objects with type classification

**Implementation Tasks:**

1. **Create EntityModule Class**
   * Implement `HostAgentModule` protocol
   * Initialize `NLTagger` with appropriate tag schemes
   * Add configuration for entity types to extract

2. **Define Entity Response Schema**
   * Structure: `{text, type, range, confidence}`
   * Entity types: `person`, `organization`, `place`, `date`, `time`, `address`
   * Support overlapping entities (e.g., "Apple Inc." as both org and product)

3. **Implement Entity Extraction Logic**
   * Use `NLTagger.enumerateTags()` to scan input text
   * Filter by configured entity types
   * Normalize date/time entities using `Foundation.DateFormatter`
   * Return character ranges for entity positions

4. **Add Pipeline Integration**
   * Allow `/ocr` endpoint to automatically invoke entity extraction via `?extract_entities=true`
   * Chain OCR output directly into entity module
   * Combine results in unified response

5. **Create Standalone Endpoint**
   * `POST /entities` for processing raw text input
   * Useful for non-OCR entity extraction (emails, documents, etc.)

**API Example:**

```json
POST /entities
{
  "text": "Meet John Smith at Apple Park on Monday at 3pm"
}

Response:
{
  "status": "success",
  "data": {
    "entities": [
      {"text": "John Smith", "type": "person", "range": [5, 15], "confidence": 0.92},
      {"text": "Apple Park", "type": "place", "range": [19, 29], "confidence": 0.88},
      {"text": "Monday", "type": "date", "range": [33, 39], "confidence": 0.95},
      {"text": "3pm", "type": "time", "range": [43, 46], "confidence": 0.90}
    ]
  }
}
```

**Configuration Example:**

```yaml
modules:
  entity:
    enabled: true
    types: [person, organization, place, date, time]
    min_confidence: 0.7
```

**Testing:**

* Test with sample text containing mixed entity types
* Validate date/time normalization
* Test integration with OCR pipeline

**Estimated Complexity:** Medium (3-4 hours)

---

### Unit 3.3 – Face Detection Module (Stub Implementation)

**Objective:** Create a functional but basic face detection module that can be extended later with face recognition and tagging capabilities.

**Technical Approach:**

* Use Vision framework's `VNDetectFaceRectanglesRequest`
* Return bounding boxes and face landmark data
* Stub out future face recognition pipeline

**Implementation Tasks:**

1. **Create FaceModule Class**
   * Implement `HostAgentModule` protocol
   * Initialize Vision face detection requests
   * Add configuration for detection parameters

2. **Implement Face Detection Endpoint**
   * `POST /face/detect` accepting image path
   * Use `VNDetectFaceRectanglesRequest` for bounding boxes
   * Optionally use `VNDetectFaceLandmarksRequest` for feature points

3. **Define Response Schema**
   * Return array of detected faces with:
     * `bounding_box`: Normalized coordinates
     * `confidence`: Detection confidence
     * `landmarks`: Optional facial feature points (eyes, nose, mouth)
     * `face_id`: Placeholder UUID for future recognition

4. **Add Quality Metrics**
   * Face quality score (blur, lighting, angle)
   * Recommend which faces are suitable for recognition
   * Filter out low-quality detections

5. **Stub Recognition Pipeline**
   * Add placeholder `POST /face/recognize` endpoint
   * Return stub response indicating future capability
   * Document integration path with Photos library

**API Example:**

```json
POST /face/detect
{
  "image_path": "/path/to/photo.jpg",
  "include_landmarks": true
}

Response:
{
  "status": "success",
  "data": {
    "faces": [
      {
        "bounding_box": {"x": 0.3, "y": 0.2, "width": 0.15, "height": 0.2},
        "confidence": 0.97,
        "quality_score": 0.85,
        "landmarks": {
          "left_eye": {"x": 0.35, "y": 0.25},
          "right_eye": {"x": 0.42, "y": 0.25},
          "nose": {"x": 0.385, "y": 0.3},
          "mouth": {"x": 0.385, "y": 0.35}
        }
      }
    ]
  }
}
```

**Configuration Example:**

```yaml
modules:
  face:
    enabled: true
    min_face_size: 0.05  # Minimum face size as fraction of image
    min_confidence: 0.8
    include_landmarks: false
```

**Testing:**

* Test with images containing multiple faces
* Validate bounding box accuracy
* Test edge cases (profile views, partially obscured faces)

**Estimated Complexity:** Medium (3-4 hours)

---

### Unit 3.4 – FileWatcher Module

**Objective:** Monitor configured local directories for new files and emit structured events for ingestion by Haven collectors.

**Technical Approach:**

* Use `DispatchSource.makeFileSystemObjectSource` for directory monitoring
* Support multiple watch directories with pattern filtering
* Queue events and expose via polling API or webhook

**Implementation Tasks:**

1. **Create FileWatcherModule Class**
   * Implement `HostAgentModule` protocol
   * Initialize file system event sources
   * Maintain event queue with configurable max size

2. **Implement Directory Monitoring**
   * Monitor directories specified in config
   * Detect events: `created`, `modified`, `deleted`, `renamed`
   * Filter by file patterns (e.g., `*.jpg`, `*.pdf`)
   * Debounce rapid successive events

3. **Create Event Queue**
   * In-memory queue with configurable capacity
   * Persist overflow to disk if queue fills
   * Support event filtering by type and pattern

4. **Add Polling Endpoint**
   * `GET /filewatcher/events` returns queued events
   * Support pagination and filtering
   * Option to acknowledge and remove events from queue

5. **Add Webhook Support (Optional)**
   * Allow config to specify webhook URL
   * POST events to webhook as they occur
   * Implement retry logic with exponential backoff

6. **Implement Watch Control Endpoints**
   * `POST /filewatcher/watch` - Add new directory to watch list
   * `DELETE /filewatcher/watch` - Remove directory from watch list
   * `GET /filewatcher/status` - List active watches and stats

**API Example:**

```json
GET /filewatcher/events?since=<timestamp>&limit=10

Response:
{
  "status": "success",
  "data": {
    "events": [
      {
        "id": "evt_123",
        "type": "created",
        "path": "/Users/me/Downloads/document.pdf",
        "timestamp": "2025-10-16T14:30:00Z",
        "size_bytes": 245678,
        "metadata": {
          "extension": "pdf",
          "filename": "document.pdf"
        }
      }
    ],
    "has_more": false
  }
}
```

**Configuration Example:**

```yaml
modules:
  filewatcher:
    enabled: true
    directories:
      - path: /Users/chrispatten/Downloads
        patterns: ["*.jpg", "*.png", "*.pdf"]
        events: [created, modified]
      - path: /Users/chrispatten/Documents/Haven
        patterns: ["*"]
        events: [created]
    event_queue_size: 1000
    debounce_ms: 500
```

**Testing:**

* Test file creation, modification, deletion detection
* Validate pattern filtering
* Test queue overflow behavior
* Test with rapid file operations

**Estimated Complexity:** High (5-6 hours)

---

### Unit 3.5 – Contacts Integration Module

**Objective:** Provide read-only access to macOS Contacts for ingestion by Haven collectors, respecting system permissions and privacy.

**Technical Approach:**

* Use `Contacts.framework` (CNContactStore)
* Request appropriate permissions on first use
* Support filtering and pagination for large contact databases
* Return standardized JSON format compatible with Haven schema

**Implementation Tasks:**

1. **Create ContactsModule Class**
   * Implement `HostAgentModule` protocol
   * Initialize `CNContactStore`
   * Handle permission request flow

2. **Implement Permission Handling**
   * Check authorization status on module start
   * Request access with user-visible prompt
   * Return clear error messages if permission denied
   * Document permission requirements in README

3. **Create Contacts Listing Endpoint**
   * `GET /contacts?limit=100&offset=0`
   * Support pagination for large contact lists
   * Return standardized contact schema

4. **Define Contact Response Schema**
   * Map CNContact properties to Haven person schema
   * Include: name, phone numbers, email addresses, postal addresses
   * Support contact photos (as base64 or file path)
   * Include contact identifiers for deduplication

5. **Add Search Endpoint**
   * `GET /contacts/search?q=john`
   * Search by name, email, or phone number
   * Use CNContact predicates for efficient queries

6. **Implement Contact Detail Endpoint**
   * `GET /contacts/{id}` - Fetch single contact by identifier
   * Return full contact details including notes and dates

7. **Add Change Tracking (Future)**
   * Stub out contact change notification observer
   * Plan for incremental sync capability

**API Example:**

```json
GET /contacts?limit=2

Response:
{
  "status": "success",
  "data": {
    "contacts": [
      {
        "id": "contact_abc123",
        "given_name": "John",
        "family_name": "Smith",
        "email_addresses": ["john@example.com"],
        "phone_numbers": [
          {"label": "mobile", "number": "+1-555-0123"}
        ],
        "postal_addresses": [
          {
            "label": "home",
            "street": "123 Main St",
            "city": "San Francisco",
            "state": "CA",
            "postal_code": "94102"
          }
        ],
        "has_photo": true,
        "modified_date": "2025-09-15T10:30:00Z"
      }
    ],
    "total": 247,
    "offset": 0,
    "limit": 2
  }
}
```

**Configuration Example:**

```yaml
modules:
  contacts:
    enabled: true
    include_photos: true
    max_page_size: 500
```

**Testing:**

* Test with test contact database
* Validate permission flow
* Test pagination with large contact lists
* Test search functionality

**Estimated Complexity:** Medium-High (4-5 hours)

---

### Phase 3 Dependencies and Prerequisites

**Before Starting Phase 3:**

* Phase 2 modularization must be complete
* Module registration system operational
* Configuration reload working
* Health check endpoint reporting module status

**Cross-Unit Dependencies:**

* Unit 3.1 and 3.2 can be integrated (OCR → Entity pipeline)
* Unit 3.4 (FileWatcher) benefits from OCR/Entity modules for automatic enrichment
* All units are otherwise independent

**Recommended Implementation Order:**

1. **Unit 3.1** (Enhanced OCR) - Extends existing working module
2. **Unit 3.2** (Entity Extraction) - Natural progression from OCR
3. **Unit 3.5** (Contacts) - Isolated, no dependencies
4. **Unit 3.3** (Face Detection) - Isolated, stub for future
5. **Unit 3.4** (FileWatcher) - Most complex, benefits from other modules

---

## API Specification (Initial)

| Method | Endpoint       | Description                               | Module       |
| ------ | -------------- | ----------------------------------------- | ------------ |
| `POST` | `/ocr`         | Perform OCR on provided image file path.  | OCRModule    |
| `POST` | `/entities`    | Extract entities from text.               | EntityModule |
| `GET`  | `/healthz`     | Returns agent health and enabled modules. | Core         |
| `POST` | `/reload`      | Reload configuration from disk.           | Core         |
| `POST` | `/face/detect` | (Future) Run face detection on image.     | FaceModule   |
| `GET`  | `/config`      | Return current configuration.             | Core         |

**Response Format Example**

```json
{
  "status": "success",
  "module": "ocr",
  "data": {
    "text": "Schedule plumber Monday 9am",
    "entities": ["plumber", "Monday", "9am"],
    "confidence": 0.97
  },
  "elapsed_ms": 162
}
```

---

## Development and Build Instructions

### Prerequisites

* macOS 14+ with Xcode Command Line Tools
* Swift 5.9+
* Access to Vision and NaturalLanguage frameworks

### Build and Run

```bash
cd hostagent
swift build --configuration release
.build/release/hostagent serve --port 8089
```

Optional launchd integration:

```bash
cp com.haven.hostagent.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.haven.hostagent.plist
```

### Integration with Haven Stack

* Collector calls: `http://host.docker.internal:8089/ocr`
* Environment variable:
  `IMDESC_CLI_PATH` → now maps to `HOSTAGENT_API_URL`
* Compatibility with existing `image_enrichment.py` via lightweight HTTP proxy class.

---

## Testing and Validation

### Local Testing

```bash
curl -X POST http://localhost:8089/ocr \
  -H "Content-Type: application/json" \
  -d '{"image_path":"/Users/me/Desktop/sample.jpg"}'
```

### Integration Test with Collector

```bash
python scripts/collectors/collector_imessage.py --simulate "Image test"
```

Collector should detect `HOSTAGENT_API_URL` and forward OCR tasks automatically.

### Unit Tests (Swift)

* Located in `Tests/HostAgentTests/`
* Cover module registration, config reload, and OCR response structure.

---

## Progress Tracking

| Phase   | Description                                           | Status        | Next Steps                                  |
| ------- | ----------------------------------------------------- | ------------- | ------------------------------------------- |
| Phase 1 | Core daemon scaffolding and OCR implementation        | ✅ Complete    | Validate under real collector load          |
| Phase 2 | Modularization and config management                  | ⏳ In progress | Implement module registry and config reload |
| Phase 3 | Extended capabilities (entities, faces, file watcher) | ⏸ Planned     | Design NaturalLanguage integration          |
| Phase 4 | Performance tuning and packaging                      | ⏸ Planned     | Benchmark OCR throughput and memory use     |

---

## Agent Instructions

### Update Protocol

Each time the coding agent performs implementation or refactoring work on HostAgent:

1. **Edit this document directly** under the relevant section (Phase, Modules, or API).
2. Update:

   * `Status` in the Progress table.
   * `Next Steps` to reflect pending work.
   * Any new APIs or configuration parameters.
3. Append a short changelog entry under the **Development Log** below.
4. Never delete completed sections; append updates chronologically.

### Development Log

| Date       | Author                | Summary                                                                                  |
| ---------- | --------------------- | ---------------------------------------------------------------------------------------- |
| 2025-10-16 | Initial Consolidation | Merged PRP, implementation guide, scaffolding summary, and status docs into unified plan |
| (next)     | (agent)               | Document updates as development progresses                                               |

