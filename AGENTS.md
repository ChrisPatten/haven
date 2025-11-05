# AGENTS.md


## Overview
* Haven agents are host-native daemons, container services, background workers, and CLI collectors that move or transform data. Each agent has a specific role and scope: 
  * **External entry point:** Gateway only.  
  * **HostAgent:** localhost-only.  
  * **No agent** interacts with internal services directly. All communication is via the gateway service API.

## Architecture
Haven turns personal data (iMessage, files, email) into searchable knowledge via hybrid search and LLM enrichment.

**Components:**
- **HostAgent (Swift, macOS)**: Native daemon collecting iMessage, local files, contacts, and email; provides OCR via Vision API. Runs on host, localhost-only. Primary entry point for `/v1/collectors/*`.
- **Gateway API (FastAPI, :8085)**: Public entry point. Validates auth, orchestrates ingestion, proxies search. Only external-facing service.
- **Catalog API (FastAPI)**: Persists documents/threads/chunks in Postgres. Tracks ingestion status.
- **Search Service (FastAPI)**: Hybrid lexical/vector search over Qdrant + Postgres.
- **Embedding Worker (Python)**: Background process vectorizing chunks via Ollama/BAAI models.

**Data Flow:**
1. Collectors/HostAgent → Gateway (validate, dedupe, queue)
2. Gateway → Catalog (persist metadata)
3. Embedding Worker → Catalog (vectorize pending chunks) → Qdrant
4. Search queries join Postgres + Qdrant

**Topology:**
```
Host (macOS) ─ HostAgent (localhost:7090)
        │
        ├─ HTTP via host.docker.internal
        ▼
Docker ─ Gateway (:8085 exposed) ─→ Catalog (8081) ─→ Postgres
                                   └─→ Search (8080) ↔ Qdrant
                                   └─→ MinIO (binaries)
Embedding Worker → Catalog → Qdrant
```

**Codebase Map:**
- `hostagent/`: Swift native daemon (legacy - being migrated to `Haven/`)
- `HavenUI/`: Original SwiftUI menubar app (legacy - being migrated to `Haven/`)
- `Haven/`: New unified Swift app combining HavenUI and HostAgent functionality
- `services/`: FastAPI microservices (gateway, catalog, search, embedding)
- `shared/`: Cross-service utilities (DB, logging, image enrichment)
- `schema/`: Postgres migrations
- `src/haven/`: Reusable Python package
- `tests/`: Pytest suite

All inter-service comm via Gateway API. No direct service-to-service calls.

## Migration: HavenUI + HostAgent → Unified Haven.App

**Status: In Progress**

We are migrating from two separate Swift applications to a single unified macOS app called `Haven.App`:

### Legacy Applications (Being Migrated)

1. **HavenUI** (`HavenUI/`):
   - Original SwiftUI menubar application
   - Provided UI for managing collectors and viewing status
   - Menubar integration with dashboard and collectors views
   - Communicated with HostAgent via localhost HTTP API

2. **HostAgent** (`hostagent/`):
   - Original Swift daemon/CLI application
   - Provided localhost HTTP API for macOS capabilities
   - Handled collectors (iMessage, email, localfs, contacts)
   - OCR and file watching functionality

### New Unified App (`Haven/`)

The new `Haven/` Xcode project consolidates both applications into a single macOS app:

- **Menubar functionality**: Complete menubar UI from HavenUI
  - Status indicator (green/yellow/red)
  - Dashboard window (Cmd+1)
  - Collectors window (Cmd+2)
  - Start/Stop controls
  - Run All Collectors functionality

- **HostAgent functionality**: Will include all HostAgent capabilities
  - Migrating from HTTP API to direct interaction with modules
  - Collector implementations
  - OCR and file watching
  - All macOS-specific data collection

**Migration Strategy:**
- Phase 1 (Current): UI components migrated from HavenUI
  - ✅ Menubar menu
  - ✅ Dashboard view
  - ✅ Collectors view
  - ✅ Basic state management
  - ✅ App icons

- Phase 2 (Next): HostAgent functionality integration
  - Transition API handlers to direct interaction with modules
  - Collector implementations
  - Async job management
  - Health polling and status updates

- Phase 3 (Future): Complete migration
  - Remove legacy HavenUI and HostAgent code
  - Consolidate all functionality in unified app
  - Update documentation

**Reference Implementation:**
- When implementing new features, reference the original implementations in:
  - `HavenUI/Sources/HavenUI/` for UI patterns
  - `hostagent/Sources/` for business logic and API handlers
- The new app should maintain feature parity with both original applications

## Documentation
**Guidelines:**
- Comprehensive docs in `/docs/`; keep updated with changes.
- Update `mkdocs.yml` for `/docs/` changes; maintain info architecture.
- Use `./.tmp` for non-app .md files.

## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Git-friendly: Auto-syncs to JSONL for version control
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

- Use the beads-mcp tool to work with beads. 
- Do not call the set_context tool, instead include the workspace_root as a parameter for each tool call.
- This project uses the prefix "hv-" for bead IDs


### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Claim your task**: `bd update <id> --status in_progress`
2. **Work on it**: Implement, test, document
3. **Discover new work?** Create linked issue:
   - `bd create "Found bug" -p 1 --deps discovered-from:<parent-id>`
4. **Complete**: `bd close <id> --reason "Done"`
5. **Commit together**: Always commit the `.beads/issues.jsonl` file together with the code changes so issue state stays in sync with code state

### Auto-Sync

bd automatically syncs with git. No user intervention is necessary:
- Exports to `.beads/issues.jsonl` after changes (5s debounce)
- Imports from JSONL when newer (e.g., after `git pull`)
- No manual export/import needed!

### Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Check `ready` before asking "what should I work on?"
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems
- ❌ Do NOT read from or modify ANYTHING in the .beads directory

## Directory Structure

**Core Application:**
- `Haven/`: New unified Swift macOS application (Xcode project)
  - `Haven/Haven/`: Main app source code (SwiftUI views, models, state)
  - `Haven/Haven.xcodeproj/`: Xcode project configuration
  - Migrating from HavenUI + HostAgent into single app

**Legacy Applications (Reference Only):**
- `HavenUI/`: Original SwiftUI menubar app (being phased out)
  - `HavenUI/Sources/HavenUI/`: UI components and views
  - Reference implementation for UI patterns
- `hostagent/`: Original Swift daemon/CLI (being phased out)
  - `hostagent/Sources/`: Business logic, collectors, HTTP API
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

- There is a symlink file `.tmp/hostagent.yaml` that points to the config file for hostagent.
- Do not commit changes to git unless asked. If asked to commit, always create a clear, complete message that reflects all of the changes.