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

## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Git-friendly: Auto-syncs to JSONL for version control
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**
```bash
bd ready --json
```

**Create new issues:**
```bash
bd create "Issue title" -t bug|feature|task -p 0-4 --json
bd create "Issue title" -p 1 --deps discovered-from:bd-123 --json
```

**Claim and update:**
```bash
bd update bd-42 --status in_progress --json
bd update bd-42 --priority 1 --json
```

**Complete work:**
```bash
bd close bd-42 --reason "Completed" --json
```

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

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task**: `bd update <id> --status in_progress`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`
6. **Commit together**: Always commit the `.beads/issues.jsonl` file together with the code changes so issue state stays in sync with code state

### Auto-Sync

bd automatically syncs with git:
- Exports to `.beads/issues.jsonl` after changes (5s debounce)
- Imports from JSONL when newer (e.g., after `git pull`)
- No manual export/import needed!

### MCP Server (Recommended)

If using Claude or MCP-compatible clients, install the beads MCP server:

```bash
pip install beads-mcp
```

Add to MCP config (e.g., `~/.config/claude/config.json`):
```json
{
  "beads": {
    "command": "beads-mcp",
    "args": []
  }
}
```

Then use `mcp__beads__*` functions instead of CLI commands.

### Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Always use `--json` flag for programmatic use
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Check `bd ready` before asking "what should I work on?"
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems

For more details, see README.md and QUICKSTART.md.
--- END AGENTS.MD CONTENT ---

2. Update CLAUDE.md (if present)
   If CLAUDE.md exists in this directory, add this note at the top:

   **Note**: This project uses [bd (beads)](https://github.com/steveyegge/beads)
   for issue tracking. Use `bd` commands instead of markdown TODOs.
   See AGENTS.md for workflow details.

3. Remove bootstrap instruction
   If AGENTS.md or CLAUDE.md contains a line like:
   "BEFORE ANYTHING ELSE: run 'bd onboard' and follow the instructions"
   Delete that line after completing steps 1 and 2.

Important reminders:
   • Use bd for ALL task tracking - NO markdown TODO lists
   • Always use --json flag for programmatic bd commands
   • Link discovered work with discovered-from dependencies
   • Check bd ready before asking "what should I work on?"
