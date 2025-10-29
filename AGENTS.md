# AGENTS.md


## Overview
* Haven agents are host-native daemons, container services, background workers, and CLI collectors that move or transform data. Each agent has a specific role and scope: 
  * **External entry point:** Gateway only.  
  * **HostAgent:** localhost-only.  
  * **No agent** interacts with internal services directly. All communication is via the gateway service API.

## Architecture
Haven turns personal data (iMessage, files, email) into searchable knowledge via hybrid search and LLM enrichment.

**Components:**
- **HostAgent (Swift, macOS)**: Native daemon collecting iMessage, email, contacts; provides OCR via Vision API. Runs on host, localhost-only.
- **Gateway API (FastAPI, :8085)**: Public entry point. Validates auth, orchestrates ingestion, proxies search. Only external-facing service.
- **Catalog API (FastAPI)**: Persists documents/threads/chunks in Postgres. Tracks ingestion status.
- **Search Service (FastAPI)**: Hybrid lexical/vector search over Qdrant + Postgres.
- **Embedding Worker (Python)**: Background process vectorizing chunks via Ollama/BAAI models.
- **Collectors (Python CLI)**: iMessage, LocalFS, Contacts scripts for data ingestion.

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
- `hostagent/`: Swift native daemon
- `services/`: FastAPI microservices (gateway, catalog, search, embedding)
- `scripts/collectors/`: Python data collectors. For reference only.
- `shared/`: Cross-service utilities (DB, logging, image enrichment)
- `schema/`: Postgres migrations
- `src/haven/`: Reusable Python package
- `tests/`: Pytest suite

All inter-service comm via Gateway API. No direct service-to-service calls.

## Documentation
**Guidelines:**
- Comprehensive docs in `/docs/`; keep updated with changes.
- Update `mkdocs.yml` for `/docs/` changes; maintain info architecture.
- Use `./.tmp` for non-app .md files.

## Work Management: beads
**Guidelines:**
- References like "bead", "beads", or "hv-27" refer to beads MCP server. Use `beads.show` for details.
- Fallback to `bd` CLI if MCP unavailable.
- **NEVER** read/edit ./.beads files directly; use MCP/CLI only.
- Commit messages: include `Refs: beads:#<id>` footer.
- Close issues: use `beads.update` with status="closed".


## Hostagent
* Always prefer Make commands from ./hostagent/Makefile
