# Beads backlog (snapshot)

_Generated: 2025-10-30T18:15:39.885795Z_

This file lists beads issues in the backlog. Use the table of contents to navigate to specific items.

## Details

### hv-1 - POC: Hostagent → Gateway → Neo4j (Life Graph)

Status: **in_progress**

```md
Stand up Neo4j in compose, add Gateway POC routes, call Hostagent for iMessage crawl (N/X days), run native extraction & merges, idempotent upsert to Neo4j, provide validation queries.
```
---

### hv-6 - Unit 4: Span→message offset mapping

Status: **open**

Priority: **1**

```md
Map NL entity spans to message offsets for proper attribution
```
---

### hv-7 - Unit 5: Task heuristics + assignee + place merge (thread-scoped)

Status: **open**

Priority: **1**

```md
Implement conversation-aware heuristics for task detection, assignee resolution, and place entity merging within thread context
```
---

### hv-13 - Epic: Finish Hostagent — build, run, test, and integrate

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

### hv-16 - Hostagent: Complete FS watch endpoints

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

### hv-24 - HostAgent: Make collector polling intervals configurable (iMessage, LocalFS, Contacts)

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

### hv-45 - README & Contributing: document docs preview and contribution process

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

### hv-51 - Migrate repository to use uv + single pyproject.toml for env & package management

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

### hv-52 - Add Google-style docstrings and API docs generation

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

### hv-59 - HostAgent mail filters test fixtures fail to load

Status: **open**

Priority: **2**

```md
Running `swift test` currently fails in `MailFiltersTests` because the YAML and JSON fixtures created on the fly are rejected by `MailFiltersLoader`. The suite reports assertion failures (expected include/exclude flags) and an `unsupportedFormat("Unable to parse filters from …yaml")` error when the loader reads temporary files. The failure is reproducible with `swift test --filter MailFiltersTests` and was observed while finishing hv-55.

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

### hv-60 - Implement relationship strength scoring

Status: **open**

Priority: **1**

```md
Design and deliver a first version of relationship scoring across the CRM data so we can nudge users toward important contacts.

Scope:
- Build daily job that computes edge-level features (days_since_last_message, messages_30d, distinct_threads_90d, avg_reply_latency, attachments_30d) for each `(self, person_id)` pairing based on existing message data.
- Produce an additive score with a recency-sensitive boost (simple SQL transformation acceptable for v1).
- Persist results in `crm_relationships(person_id, score, last_contact_at, decay_bucket)` or equivalent table/schema.
- Ensure scores are recomputed on an ongoing cadence.
- Surface a `GET /v1/crm/relationships/top?window=90d` endpoint via the Gateway API returning the best-matching relationships with relevant metadata.
- Document data model updates and endpoint usage in /docs/.

Non-goals:
- ML-based scoring beyond simple weighting.
- Building UI surfaces beyond the API response.
```
---

### hv-61 - Design CRM relationship schema

Status: **open**

Priority: **1**

```md
Define the storage model for relationship scores and metadata. Produce migration(s) for the `crm_relationships` table or equivalent and align indexes for query patterns.
```
---

### hv-62 - Implement relationship feature aggregation

Status: **open**

Priority: **1**

```md
Build the data pipeline that computes edge-level communication features (days_since_last_message, messages_30d, distinct_threads_90d, avg_reply_latency, attachments_30d) for each (self, person_id) pairing.
```
---

### hv-63 - Schedule recurring relationship scoring job

Status: **open**

Priority: **2**

```md
Add orchestration to refresh relationship features and scores on a reliable cadence (cron, Celery beat, or equivalent). Ensure backfill and failure handling.
```
---

### hv-64 - Expose top relationships API

Status: **open**

Priority: **1**

```md
Add GET /v1/crm/relationships/top?window=90d (with window param support) to Gateway. Query relationship scores, enforce window filtering, and return person metadata.
```
---

### hv-65 - Harden relationship scoring with tests and docs

Status: **open**

Priority: **2**

```md
Add automated coverage for the scoring job and Gateway endpoint, plus document the pipeline and API usage in /docs/.
```
---

