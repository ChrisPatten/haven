```markdown
# AGENTS.md

## 0. TL;DR
* Agents are host-native daemons, container services, background workers, and CLI collectors that move or transform data.  
* **External entry point:** Gateway only.  
* **HostAgent:** localhost-only.  
* **No agent** writes directly to Postgres, Qdrant, or MinIO except via prescribed routes.
* If the user mentions "bead", "beads", or references beads by name like "haven-27" or "hv-27", they are referring to the planning and work-tracking system available via the beads MCP server. Call the `beads.show` tool to retrieve relevant information.
  * If the MCP server is not available, fall back to using the `bd` command-line tool to retrieve information about beads.
* Review the documentation in /docs/ as necessary for developer onboarding and architecture overviews.
* Unless specifically instructed to do otherwise, any new .md files created MUST be placed in .tmp/. "Otherwise" means specific guidance to update permanent documentation. In this case, integrate the new information into the /docs/ directory for inclusion in the mkdocs site.
* When I ask you to create documentation, consider it an "Otherwise" scenario. Review the existing mkdocs yaml and the documentation structure and create or update accordingly (including both creating/updating .md files and configuring it in the mkdocs yaml).
* **NEVER** edit the files in .beads/ directly. All changes must be made via the beads MCP server or the `bd` CLI tool to ensure proper versioning and tracking.
* When writing commit messages, include the relevant beads issue ID in the footer as `Refs: beads:#<id>`. Do not include references to the files in the .beads/ directory in commit messages.
* When executing swift commands, prepend them with arch -x86_64 to ensure compatibility with Intel-based dependencies.


---

## 1. Topology



[Host (macOS)]
HostAgent (:7090, localhost only)
↕ (HTTP via host.docker.internal)
[Docker network]
Gateway (:8085, exposed) → Catalog (:8081) → Postgres
↘︎ Search (:8080) ↔ Qdrant
↘︎ MinIO (files)
Embedding Worker → Postgres (chunks) → Catalog (/v1/catalog/embeddings)



**Key rules**
- All ingestion/search occurs via Gateway.  
- Binaries are stored in MinIO and deduplicated by SHA256.  
- Catalog is the source of truth for documents, versions, and chunks.  
- Gateway orchestrates ingestion pipelines across services.

---

## 2. Agent Catalog

| Agent            | Role & Scope | Interfaces | Inputs/Outputs | Idempotency | Auth/Perms | Perf/Limits | Observability | Failure Policy | Data Residency |
|------------------|--------------|-------------|----------------|--------------|-------------|--------------|----------------|----------------|----------------|
| **HostAgent** | macOS-native OCR/FS/Contacts; exposes localhost API | `/v1/ocr`, `/v1/face/detect`, `/v1/fswatch`, `/v1/collectors/imessage:run` | images → OCR/entities; file events | handled upstream | `x-auth` header; macOS TCC/FDA | timeouts per op | `/v1/health`, `/v1/capabilities` | returns errors, caller retries | never uploads raw files except via Gateway |
| **Gateway** | Public API (ingest/search/orchestration) | `/v1/ingest`, `/v1/ingest/file`, `/v1/search`, `/v1/ask` | v2 Document payloads; file uploads | `ingest_submissions.idempotency_key` | Bearer token | request/response SLAs | `/v1/healthz`; logs keyed by `submission_id` | 4xx/5xx safe to retry | routes to Catalog/Search/MinIO |
| **Catalog API** | Persistence, versioning | `/v1/catalog/documents`, `/v1/catalog/embeddings` | documents/files/chunks | content hash + versioning | internal token | transactional inserts | `/v1/healthz`; doc/chunk status | mark failed states; manual reset | Postgres only |
| **Search Service** | Hybrid lexical/vector search | `/v1/search` | chunks + vectors | n/a | internal token | vector dims/model | query timing logs | degrade to lexical | no PII in logs |
| **Embedding Worker** | Generates vectors | polls `chunks` table; posts `/v1/catalog/embeddings` | text → vectors | chunk status gates | provider creds | batch size, poll interval | job counters; error rates | mark failed; manual retry | vectors in Qdrant |

---

## 5. Security & Privacy

* Only Gateway (`:8085`) is externally exposed.
* Use Bearer tokens for all API calls.
* Treat `~/.haven` and `~/Library/Messages/chat.db` as sensitive.
* HostAgent requests full-disk access and contacts permission via macOS TCC/FDA in production.
* For development, use `HAVEN_IMESSAGE_CHAT_DB_PATH` to work with a copy in `~/.haven/chat.db`.
* MinIO is the system of record for files; enrichment and embeddings stored separately.

---

## 6. Change Management

* **API versioning:** `/v1` → `/v2` with deprecation window.
* **Schema changes:** prefer re-ingestion over complex migrations.
* **Adding a new agent checklist:**

  1. Add a table row in §2 (all columns).
  2. Add observability and metric keys.

---

## 7. Testing Matrix

* **Unit:** each service package.
* **Integration:** ingest → cataloged → embedded → searchable.

---

## 8. FAQ / Pitfalls

* **Zero vector hits:** embeddings not yet populated.
* **409 Conflict on ingest:** duplicate idempotency key.
* **Missing attachment OCR:** file missing on disk or helper misconfigured.

---

## 9. MCP Servers (Authoritative)

We use the **Model Context Protocol (MCP)** to expose tool surfaces to coding agents.
**Beads** is our planning and memory server — the source of truth for agent-executable work graphs and dependencies.

### 9.1 Configuration

Clients (Cursor, Claude Desktop, etc.) must register Beads in their MCP config:

```json
{
  "mcpServers": {
    "beads": { "command": "beads-mcp" }
  }
}
```

Tools exposed:
`beads.create`, `beads.update`, `beads.list`, `beads.dep.add`, `beads.ready`, `beads.show`, `beads.reopen`, `beads.blocked`

### 9.2 Work Graph Contract

* **Required fields:** `title`, `body`, `priority {P0–P3}`, `size {XS–XL}`
* **Labels:** `service/*`, `domain/*`, `type/{bug,task,design,doc}`, `risk/{low,med,high}`
* **Dependencies:** `blocks`, `requires`, `relates`, `dupe_of`
* **State model:** `todo → ready → doing → blocked → done`

  * Agents may: `todo→ready`, `ready→doing`, `doing→blocked/done`
  * Humans must approve: `blocked→ready`

### 9.3 Ready-Work Discipline

Agents **must** query `beads.ready` before starting work to confirm readiness of a user's requested task.
If no ready tasks exist, create a `blocked` issue describing the missing dependency and link via `requires`.

### 9.4 Repo ↔ Beads Linking

* Every PRP/Epic/Task includes `Beads: beads:#<id>` in its header.
* Commits append `Refs: beads:#<id>` in their footer.
* Logs include `beads_issue_ids` for correlation and observability.

### 9.5 Storage & Review

Beads uses a **git-backed DB**.
Treat Beads graph updates like code:

* Review diffs.
* Protect `beads/` paths from force pushes.
* Enforce branch rules.

### 9.6 Failure & Recovery Patterns

* On runtime failure:

  * `beads.create` a **blocked** child summarizing error, logs, and diagnostic step.
  * Add a `blocks` dependency on the parent.
* On design uncertainty:

  * Create a `design spike` issue with `timebox` metadata and link via `relates`.

### 9.7 Examples

**Create a task with dependencies**

```bash
beads.create '{
  "title": "LocalFS collector: post to Gateway /v1/ingest/file",
  "labels": ["service/gateway","type/task","risk/med","domain/ingestion"],
  "priority": "P1",
  "size": "M",
  "body": "Implement watcher → MinIO via Gateway; include SHA256 dedup + idempotency_key.",
  "dependencies": [
    {"type":"requires","issue":"beads:#120"},
    {"type":"requires","issue":"beads:#118"}
  ]
}'
```

**Move work to doing**

```bash
beads.ready
beads.update '{"id":142,"state":"doing"}'
```

**Record a failure**

```bash
beads.create '{
  "title": "Upload 413 at 64MB",
  "labels": ["service/gateway","type/bug"],
  "priority": "P1",
  "size": "S",
  "body": "Gateway rejects uploads > 50MB; need chunked upload or limit bump.",
  "dependencies": [{"type":"blocks","issue":"beads:#142"}]
}'
```

**Close completed work**

```bash
beads.update '{
  "issue_id": "haven-29",
  "status": "closed",
  "notes": "Implemented .emlx parsing, metadata extraction, intent classification, noise detection, PII redaction; added HostAgent HTTP endpoints, tests (22), fixtures, and documentation. Build and tests pass locally.",
  "workspace_root": "/Users/chrispatten/workspace/haven"
}'
```

### 9.8 Guardrails

* Beads **plans**, Gateway **executes**.
  Agents never mutate infrastructure directly based on Beads alone.
* Secrets are never stored in Beads issues — reference vault paths instead.
