# AGENTS.md


## Overview
* Haven agents are host-native daemons, container services, background workers, and CLI collectors that move or transform data. Each agent has a specific role and scope: 
  * **External entry point:** Gateway only.  
  * **Haven.app:** macOS-native SwiftUI application running collectors directly.  
  * **No agent** interacts with internal services directly. All communication is via the gateway service API.

## Architecture
Haven turns personal data (iMessage, files, email) into searchable knowledge via hybrid search and LLM enrichment.

**Components:**
- **Haven.app (Swift, macOS)**: Unified SwiftUI menu bar application that runs collectors directly via Swift APIs. Collects iMessage, local files, contacts, email, and reminders. Provides OCR, face detection, entity extraction, and captioning via native macOS APIs. Runs on host, communicates with Gateway via `host.docker.internal:8085`. No HTTP server required - collectors run directly in-process.
- **Gateway API (FastAPI, :8085)**: Public entry point. Validates auth, orchestrates ingestion, proxies search. Only external-facing service.
- **Catalog API (FastAPI)**: Persists documents/threads/chunks in Postgres. Tracks ingestion status.
- **Search Service (FastAPI)**: Hybrid lexical/vector search over Qdrant + Postgres.
- **Worker Service (Python)**: Background workers for vectorizing chunks (embedding worker) and processing intents (intents worker) via Ollama/BAAI models.

**Haven.app Architecture (Layered Separation):**

The Haven.app is architected with clear separation of concerns across four main layers:

1. **UI Layer** (`Haven/Haven/Views/`): SwiftUI views and ViewModels
   - `CollectorsView`, `DashboardView`, `SettingsWindow` - main UI windows
   - `CollectorDetailView`, `CollectorListSidebar` - collector management UI
   - `Scope/` views for collector-specific configuration (iMessage, Email, Files, etc.)
   - `ViewModels/` - presentation logic and state management

2. **Controller Layer** (`Haven/Haven/Controllers/`): Orchestration and coordination
   - `HostAgentController`: Main orchestration controller managing lifecycle, collector initialization, and job dispatch
   - Individual `CollectorController` implementations (`IMessageController`, `EmailController`, `LocalFSController`, etc.)
   - `ServiceController`: Manages gateway client and service initialization
   - `JobManager`: Tracks collector runs as background jobs with progress monitoring and cancellation support
   - Controllers implement the `CollectorController` protocol for consistent interface

3. **Collector Layer** (`hostagent/Sources/CollectorHandlers/Handlers/`): Data collection handlers
   - `IMessageHandler`, `EmailImapHandler`, `LocalFSHandler`, `ICloudDriveHandler`, `ContactsHandler`, `RemindersHandler`
   - Handlers perform the actual collection work: reading from data sources, extracting content, building document payloads
   - Each handler receives an optional `EnrichmentOrchestrator` and `DocumentSubmitter` for processing and submission

4. **Enrichment & Submission Layer** (`hostagent/Sources/HostAgent/`): Processing and submission
   - **Enrichment** (`Enrichment/`): 
     - `EnrichmentOrchestrator` coordinates enrichment services:
       - OCR via Vision API (`OCRService`)
       - Face detection (`FaceService`)
       - Entity extraction (`EntityService`)
       - Image captioning (`CaptionService`)
     - `EnrichmentQueue`: FIFO queue with dual worker pools (normal workers + no-attachment worker) for concurrent enrichment processing
   - **Submission** (`Submission/`): Document submission abstraction
     - `DocumentSubmitter` protocol for submission interface with buffering, flush, finish, and statistics tracking
     - `BatchDocumentSubmitter`: Buffers documents, batches them (default: 200), and submits via `GatewaySubmissionClient` with automatic flushing
     - `DebugDocumentSubmitter`: Writes documents to disk for debugging
     - `GatewaySubmissionClient`: HTTP client for Gateway API communication

**Data Flow:**
1. User triggers collector via UI → Controller → Handler
2. Handler collects data → EnrichmentQueue (if enrichment enabled) → EnrichmentOrchestrator → DocumentSubmitter
3. EnrichmentQueue uses dual worker pools (normal + no-attachment) for optimal throughput
4. DocumentSubmitter buffers documents and batches them (default: 200) → Gateway (validate, dedupe, queue)
5. Gateway → Catalog (persist metadata)
6. Worker Service → Catalog (vectorize pending chunks, process intents) → Qdrant
7. Search queries join Postgres + Qdrant

**Progress Tracking:**
- Collectors track granular progress metrics: scanned, matched, submitted, skipped, errors, found, queued, enriched
- JobManager monitors collector runs with real-time progress updates
- UI displays detailed progress with processing states (Found, Queued, Enriched, Submitted)

**Topology:**
```
Host (macOS) ─ Haven.app (SwiftUI app, no HTTP server)
        │
        │  ┌─ UI Layer (Views, ViewModels)
        │  └─ Controller Layer (HostAgentController, CollectorControllers)
        │  └─ Collector Layer (Handlers)
        │  └─ Enrichment & Submission Layer
        │
        ├─ HTTP via host.docker.internal:8085
        ▼
Docker ─ Gateway (:8085 exposed) ─→ Catalog (8081) ─→ Postgres
                                   └─→ Search (8080) ↔ Qdrant
                                   └─→ MinIO (binaries)
Worker Service → Catalog → Qdrant
```

**Codebase Map:**
- `Haven/`: Unified Swift macOS application (Xcode project)
  - `Haven/Haven/`: Main app source code
    - `Views/`: SwiftUI views (collectors, dashboard, settings)
    - `Controllers/`: Orchestration controllers (HostAgentController, CollectorControllers)
    - `ViewModels/`: Presentation logic
    - `Managers/`: State and configuration management
    - `JobManager/`: Background job tracking
    - `Configuration/`: Configuration models and management
- `hostagent/`: Swift package providing collector handlers and core functionality
  - `Sources/CollectorHandlers/Handlers/`: Collector handler implementations
  - `Sources/HostAgent/`: Enrichment orchestrator, submission clients, collectors
  - `Sources/HavenCore/`: Shared utilities (logging, config, file paths, extractors)
- `services/`: FastAPI microservices (gateway, catalog, search, worker_service)
- `shared/`: Cross-service utilities (DB, logging, image enrichment)
- `schema/`: Postgres migrations
- `src/haven/`: Reusable Python package
- `tests/`: Pytest suite

All inter-service comm via Gateway API. No direct service-to-service calls.

**Reference Implementation:**
- When implementing new features, reference the original implementations in:
  - `HavenUI/Sources/HavenUI/` for UI patterns (legacy, being phased out)
  - `hostagent/Sources/` for business logic and API handlers

## Documentation
**Guidelines:**
- Comprehensive docs in `/docs/`; keep updated with changes.
- Update `mkdocs.yml` for `/docs/` changes; maintain info architecture.

## Directory Structure

**Core Application:**
- `Haven/`: Unified Swift macOS application (Xcode project)
  - `Haven/Haven/`: Main app source code
    - `Views/`: SwiftUI views (collectors, dashboard, settings, scope panels)
    - `Controllers/`: Orchestration layer (HostAgentController, CollectorControllers, ServiceController)
    - `ViewModels/`: Presentation logic and state management
    - `Managers/`: State management (StateManager, EnrichmentConfigManager)
    - `JobManager/`: Background job tracking and progress monitoring
    - `Configuration/`: Configuration models and management (ConfigManager, instance configs)
    - `Models.swift`, `AppState.swift`: Core data models and application state
  - `Haven/Haven.xcodeproj/`: Xcode project configuration
  - `HavenTests/`, `HavenUITests/`: Test suites

**Collector Infrastructure (Swift Package):**
- `hostagent/`: Swift package providing collector handlers and core functionality
  - `Sources/CollectorHandlers/Handlers/`: Collector handler implementations
    - `IMessageHandler.swift`: iMessage collection
    - `EmailImapHandler.swift`: IMAP email collection
    - `LocalFSHandler.swift`: Local filesystem collection
    - `ICloudDriveHandler.swift`: iCloud Drive collection
    - `ContactsHandler.swift`: Contacts collection
    - `RemindersHandler.swift`: Reminders collection
  - `Sources/HostAgent/`: Core HostAgent functionality
    - `Enrichment/`: Enrichment orchestrator and queue management
    - `Submission/`: Document submission (DocumentSubmitter protocol, BatchDocumentSubmitter, DebugDocumentSubmitter, GatewaySubmissionClient)
    - `Collectors/`: Legacy collector implementations (being phased out)
  - `Sources/HavenCore/`: Shared utilities and infrastructure
    - `Logging.swift`: Structured logging
    - `Config.swift`: Configuration models
    - `Gateway.swift`: Gateway client utilities
    - `FilePaths.swift`: Standard file path management
    - `TextExtractor.swift`, `ImageExtractor.swift`: Content extraction utilities
    - `FenceManager.swift`: State tracking and deduplication
    - `EventKit/`: EventKit integration for Reminders

**Legacy Applications (Reference Only):**
- `HavenUI/`: Original SwiftUI menubar app (being phased out)
  - `HavenUI/Sources/HavenUI/`: UI components and views
  - Reference implementation for UI patterns
- `hostagent/Sources/HostAgent/Collectors/`: Legacy collector implementations (being phased out)
  - Reference implementation for backend functionality

**Backend Services:**
- `services/`: FastAPI microservices
  - `gateway_api/`: Public API gateway
  - `catalog_api/`: Document persistence service
  - `search_service/`: Hybrid search service
  - `embedding_service/`: Vectorization worker

**Shared Code:**
- `shared/`: Cross-service Python utilities
- `src/haven/`: Reusable Python package
- `schema/`: Database migrations

**Documentation:**
- `docs/`: MkDocs documentation source
- `documentation/`: Additional reference docs

**Testing:**
- `tests/`: Python test suite
- `hostagent/Tests/`: Swift tests (legacy)

**Build & Configuration:**
- `openapi/`: API specifications
- `scripts/`: Build and utility scripts
- `build-bundle/`: Build artifacts (not in git)

## Miscellaneous

- Do not create documentation or summary files unless asked.
- Do not commit changes to git unless asked. If asked to commit, always create a clear, complete message that reflects all of the changes.
- When building `Haven.app` always use xcodebuild to build the app.
- Data is primarily persisted in the Postgres service defined in the `compose.yaml` file. You can use the `docker compose exec postgres psql -U postgres -d haven` command to access the database. Review the `schema/init.sql` file to understand the schema if you need to explore the data.