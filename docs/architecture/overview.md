# Architecture Overview

Haven is a personal data plane that runs primarily on the developer’s machine. Host-native collectors gather content, Gateway orchestrates ingestion, Catalog persists unified records, and downstream services keep the corpus searchable. This page summarises the end-to-end flow and the components involved.

## System Context

- **Haven.app (macOS)** is a unified SwiftUI menu bar application that runs collectors directly via Swift APIs. It communicates with Gateway via `host.docker.internal:8085`.
- **Gateway API** is the only externally exposed service (`:8085`). It validates payloads, enforces auth, orchestrates ingestion, and fronts hybrid search.
- **Catalog API** persists documents, threads, files, and chunk metadata in Postgres. It is the source of truth for document versions and ingestion status.
- **Search Service** combines lexical and vector search backed by Qdrant, offering filters, timeline views, and summarisation helpers.
- **Embedding Worker** consumes pending chunks, generates vectors, and posts results back to Catalog so search stays up to date.

Supporting datastores include Postgres (primary), Qdrant (vectors), and MinIO (binary attachments). All binaries flow through Gateway for deduplication and storage.

## Data Flow at a Glance
1. **Collectors emit payloads** — Haven.app (iMessage, Contacts, filesystem watchers) or CLI collectors normalise source data and send them to Gateway. Haven.app runs collectors directly via Swift APIs (no HTTP server required).
2. **Gateway validates and queues** — It computes idempotency keys, attaches metadata, and forwards the document payload to Catalog while staging files in MinIO.
3. **Catalog persists state** — Documents, threads, files, and chunks are written transactionally. Ingest submissions capture status for retries and audit trails. People are normalized via `PeopleRepository`, identifiers canonicalized, and linked to documents via `document_people`.
4. **Embedding worker enriches** — Pending chunks are vectorised and written via `/v1/catalog/embeddings`, flipping their status to `embedded`.
5. **Search exposes results** — Hybrid search queries join Catalog tables with Qdrant vectors, enabling Ask/answer workflows and filtered exploration. People search queries the normalized `people` table.
6. **Relationship scoring** — Background job computes relationship strength from message history, updating `crm_relationships` table.

## Topology

```
Host (macOS) ── Haven.app (SwiftUI + Collector Runtime)
        │
        ├─ HTTP via host.docker.internal
        ▼
Docker network ── Gateway (8085 → exposed) ─→ Catalog (8081) ─→ Postgres
                                   └─→ Search (8080) ↔ Qdrant
                                   └─→ MinIO (binary storage)
Embedding worker → Catalog (chunks) → Qdrant (vectors)
```

**Architecture Note**: Haven.app integrates collector functionality directly, eliminating the need for a separate HTTP server. Collectors run via direct Swift API calls within the app, which then communicates with Gateway over `host.docker.internal:8085`.

Gateway is the only service reachable from outside the Docker network. All other services are internal and rely on shared secrets or bearer tokens for access.

## Security and Privacy Posture
- Collectors and Haven.app never write directly to Postgres, Qdrant, or MinIO; everything routes through Gateway.
- Files remain on-device unless explicitly uploaded via Gateway. Even then, MinIO is scoped to the local deployment.
- Haven.app requires Full Disk Access and Contacts permission on macOS. Development-mode guidance uses copies under `~/.haven/`.
- Authentication:
  - Gateway requires bearer tokens (`AUTH_TOKEN`).
  - Internal services use shared secrets or per-service tokens.

## Environment Parity
- **Local development** relies on Docker Compose plus Haven.app (optional but recommended). Collectors communicate with Gateway via `host.docker.internal:8085`.
- **Staging/production** deployments keep the same topology with hardened secrets, managed MinIO, and persistent Postgres/Qdrant instances. Schema migrations run automatically on boot, and embedding workers scale horizontally as needed.

_Adapted from `documentation/technical_reference.md` and `.tmp/docs/index.md`._
