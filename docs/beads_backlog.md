# Beads backlog (snapshot)

_Generated: 2025-10-29T03:05:17.549898Z_

This file lists beads issues in the backlog. Use the table of contents to navigate to specific items.

## Details

### hv-1 - Unit 9 (docs): README_poc.md — finalize after units 2/4/5/8

Status: **open**

Priority: **1**

```md
Final POC README with 3–4 commands to run and verification steps. This task must wait until Units 2, 4, 5, and 8 are complete.
```
---

### hv-2 - Epic: Finish Hostagent — build, run, test, and integrate

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

### hv-3 - hostagent: validate & consolidate hostagent.yaml format

Status: **open**

Priority: **2**

```md
Double-check, clean up, and consolidate the `hostagent.yaml` configuration format used by HostAgent. This task will: 1) review the current `.tmp/hostagent.bak.yaml` (provided by user) and any other hostagent config examples; 2) produce a single canonical `hostagent.yaml` schema (keys, types, defaults); 3) merge and clean duplicate/legacy keys; 4) add simple validation (schema or unit tests) and update docs so other contributors follow the canonical format.
```
---

### hv-4 - POC: Hostagent → Gateway → Neo4j (Life Graph)

Status: **open**

```md
Stand up Neo4j in compose, add Gateway POC routes, call Hostagent for iMessage crawl (N/X days), run native extraction & merges, idempotent upsert to Neo4j, provide validation queries.
```
---

### hv-5 - Add OpenAPI exporter endpoint to HostAgent runtime

Status: **open**

Priority: **2**

```md
Goal
Add a canonical, runtime OpenAPI exporter to the HostAgent Swift service so the service can serve its OpenAPI spec (JSON and/or YAML) and be the single source-of-truth for API docs. This will eliminate spec drift and allow automation (mkdocs/exporter) to fetch the live spec during docs builds or CI.

Background
Currently the repo contains a static `openapi/hostagent.yaml` authored by hand and a Python exporter that writes a Redoc page for it. HostAgent is a macOS-native Swift service; there is no runtime OpenAPI endpoint. That produces drift risk when new routes or request/response schemas are added in Swift.

Scope
- Add an endpoint to HostAgent that exposes the service's OpenAPI specification at `/openapi.json` and `/openapi.yaml` (YAML optional). The endpoint should be enabled in dev/build configurations and guarded behind admin or local-only access in production if required by config.
- Generate OpenAPI programmatically from the HostAgent router/handlers and bundled JSON schemas in `Resources/*/schemas/*.schema.json` (merge into components.schemas). If full programmatic generation is infeasible, provide a build-time task that composes the OpenAPI spec from route metadata + JSON schemas and writes a file to `Resources/OpenAPI/hostagent.yaml` that the server serves statically.
- Ensure the exporter includes the Collector routes, email utilities, FSWatch, face detection, OCR, entities, modules, metrics, and health endpoints already present in the router.
- Add minimal tests that exercise the endpoint and verify the presence of key paths and the `CollectorRunRequest` schema in components.
- Update docs/dev workflow: the Python `scripts/export_openapi.py` (or docs hooks) can optionally fetch the runtime `/openapi.yaml` (if server running) or read the build-time generated `Resources/OpenAPI/hostagent.yaml` during docs builds/CI.

Design notes
- Runtime approach (preferred long-term): implement a small OpenAPI-builder utility in Swift that walks the Router/PatternRouteHandler registrations and collects path patterns, methods, and handler metadata. For each route, include a path entry with sensible default request/response schemas, and resolve component schemas by importing JSON schema files from Resources.
  - Expose endpoints: `/openapi.json` and `/openapi.yaml` (Content-Type application/json / application/x-yaml).
  - Add a config toggle: `openapi.enabled: true|false`, default true in dev, false in production unless explicitly enabled.
  - Secure the endpoint optionally with the hostagent auth header (configurable) or limit to localhost only.

- Build-time fallback (lower risk): add a Swift PackageTarget/tool that generates `Resources/OpenAPI/hostagent.yaml` from the same route discovery utility and schema files. Add a Makefile or SPM run target `swift run hostagent-openapi --emit-resources` to write the file into `Resources/OpenAPI/` which will be bundled and served as static files.

Acceptance criteria
- The HostAgent binary serves an OpenAPI spec at `/openapi.yaml` when `openapi.enabled` is true (or the generated resource file exists). The spec includes paths for collectors (including `imessage` and `email_imap`) and contains `components.schemas.CollectorRunRequest` matching the JSON schema in `Resources/Collectors/schemas/collector_run_request.schema.json`.
- Unit/integration test that makes a local request to `/openapi.yaml` and asserts the spec contains `/v1/collectors/imessage:run` and `components.schemas.CollectorRunRequest`.
- `scripts/export_openapi.py` can optionally be updated to fetch the runtime `/openapi.yaml` (if server available) during docs builds — documented in the README/dev docs.

Implementation tasks
1. Add a new Swift module `HostOpenAPI` or utility inside HostAgent to build the spec.
2. Implement route-walker that introspects `Router` / `PatternRouteHandler` registrations.
3. Merge JSON schemas from `Resources/**/schemas/*.schema.json` into `components.schemas`.
4. Expose endpoints `/openapi.json` and `/openapi.yaml` (serve YAML by converting internal JSON using a YAML serializer or pre-generate YAML at build time).
5. Add config flag to enable/disable endpoint and optional local-only/auth restrictions.
6. Add tests covering presence of key paths and schemas.
7. Optional: update `scripts/export_openapi.py` doc/comments to support fetching runtime spec.

Notes / Risks
- Programmatic route introspection in Swift depends on the router implementation. If introspection is not possible, the build-time generator fallback will be used.
- Care must be taken to not leak sensitive data (authentication headers, internal endpoints). Default to local-only in production.

Estimate
- Design + prototype: 1–2 days
- Implementation + tests + docs: 2–4 days
```
---

### hv-6 - Hostagent: Complete FS watch endpoints

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

### hv-7 - Hostagent: Stub Contacts collector endpoint

Status: **open**

Priority: **1**

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

### hv-8 - Hostagent: Port macOS Contacts collector (collector_contacts.py) to Swift

Status: **open**

Priority: **2**

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

### hv-9 - HostAgent: Make collector polling intervals configurable (iMessage, LocalFS, Contacts)

Status: **open**

Priority: **2**

```md
Add configuration and runtime controls to set polling intervals for HostAgent collectors (iMessage, LocalFS, Contacts, and any future collectors).

Background:
HostAgent currently runs collectors on fixed schedules. Operators need the ability to tune polling frequency per-collector to balance CPU/IO, battery, and timeliness. This task adds config, runtime endpoints, and documentation.

Acceptance criteria:
- Add per-collector polling interval configuration via: 1) `hostagent.yaml` config file (per-collector keys), 2) environment variables `HOSTAGENT_<COLLECTOR>_POLL_INTERVAL_SEC`, and 3) CLI flags for simulate/test runs.
- Implement runtime endpoints: `GET /v1/collectors/{collector}/poll_interval` and `POST /v1/collectors/{collector}/poll_interval` to view and update the interval without restart. POST accepts `{ "interval_seconds": <number> }` and validates min/max bounds.
- Ensure iMessage, LocalFS, and Contacts collectors read the effective interval and apply it for scheduling/backoff; new collectors should reuse the same scheduling helper.
- Validate that changes via environment, config file, and runtime API follow this precedence: API update > env var > config file > default (60s). Document this precedence in `AGENTS.md` and `hostagent/QUICKSTART.md`.
- Add unit tests for scheduling helper and integration tests that simulate changing the poll interval at runtime and confirm the collector respects the new interval within one cycle.
- Add labels: `service/hostagent`, `type/task`, `risk/low`, `priority:P2`.

Notes:
- Use sensible min/max (min 5s, max 86400s = 1 day) and defensive validation.
- Prefer a small, shared scheduling utility that emits schedule ticks and supports update at runtime and backoff.
- Keep changes backwards compatible; default behavior remains current schedule if no config provided.
```
---

### hv-10 - Publish Docs with MkDocs + Material

Status: **open**

Priority: **1**

```md
## Summary

Create a first-class documentation system for Haven by introducing a `/docs/` folder and publishing a static site using **MkDocs** with the **Material** theme. Wire in an **API documentation section** that renders the project's OpenAPI spec as an interactive reference.

## Goals

Centralize product, architecture, and operations docs under `/docs/`.
Publish a branded, searchable docs site with a stable URL.
Expose the OpenAPI spec through an interactive UI with deep links and permalinks.
Adopt a "docs as code" workflow with PR reviews.

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

The site must surface the project's OpenAPI spec (e.g., `/openapi/openapi.yaml` or `/openapi/openapi.json`) as an interactive API reference under `/api/`.
The API page must provide: tag navigation; operation details with request/response schemas; schema/model browsing; server/endpoint selection if defined; and stable deep links to operations and schemas.
The API reference must be generated at build time from the spec in the repo, so PRs that change the spec update the published reference automatically.
If multiple specs exist (e.g., `gateway`, `catalog`), the `/api/` section must list and route to each spec clearly (e.g., `/api/gateway/`, `/api/catalog/`).
A "Download spec" link must be present for each exposed spec.
Document the canonical spec locations (e.g., `/openapi/gateway.yaml`, `/openapi/catalog.yaml`) and require that they remain valid for the build.

## Deliverables

A live docs site reachable at a stable URL.
`/docs/` folder populated with the IA above.
`mkdocs.yml` configured for Material theme, repo links, navigation, and search.
An `/api/` section that renders the OpenAPI spec(s) from the repo with interactive exploration and deep linking.
A "Documentation" section in `README` that links to the site and explains how to preview docs locally and contribute via PRs.

## Acceptance Criteria

Visiting the site root shows the Material-styled landing page and working search.
Dark/light mode works, code blocks have copy buttons, and admonitions render correctly.
The `/api/` section loads the OpenAPI reference from the repo and supports tag filtering, operation details, schema browsing, and deep links that remain stable after rebuilds.
Changes to `/docs/**`, `mkdocs.yml`, or `/openapi/**` result in an updated published site.
The API page(s) display a visible "Download spec" link that returns the exact spec version used to render the page.

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

This establishes a durable "docs as code" foundation with strong UX and a first-class API reference tied to the repo's source of truth.

## Next Steps

Confirm canonical OpenAPI file paths and names.
Adopt the IA and stub pages.
Enable CI publish of the site and spec-driven API reference.
```
---

### hv-11 - README & Contributing: document docs preview and contribution process

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

### hv-12 - Unit 3: Hostagent POST /poc/crawl (threads/messages/extract)

Status: **open**

```md
Add POC endpoint to hostagent for thread discovery, message extraction, and native NL processing
```
---

### hv-13 - Migrate repository to use uv + single pyproject.toml for env & package management

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

### hv-14 - Add Google-style docstrings and API docs generation

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

### hv-15 - MKDocs integration notes for haven-52 (docstrings + mkdocs)

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

### hv-16 - HostAgent mail filters test fixtures fail to load

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

### hv-17 - Unit 4: Span→message offset mapping

Status: **open**

Priority: **1**

```md
Map NL entity spans to message offsets for proper attribution
```
---

### hv-18 - Remote IMAP Email Collector (epic): ephemeral .eml backfill & run-scoped cache

Status: **in_progress**

Priority: **1**

```md
Implement an IMAP-based remote collector (MailCore 2) that streams RFC822 bytes to ephemeral .eml files while running, hands them to the existing hostagent .eml/.emlx parser, and deletes the cache directory on exit. Support timeframe-batched backfill (newest→older windows). No POP support.

Design & deliverables:
1) IMAP Collector (Swift, MailCore 2): Async wrapper `ImapSession` around `MCOIMAPSession` exposing search and fetch APIs. Auth: pluggable for XOAUTH2 and app-password. Secrets resolved via Keychain `secret_ref`.

2) Ephemeral Cache Manager: Run-scoped root directory (e.g., `~/.Caches/Haven/remote_mail/run-<timestamp>-<pid>/`). Atomic write: `.eml.tmp` → `*.eml` rename; parser consumes only finalized `.eml` files. Enforce `max_mb` (default 100MB) by evicting already-processed files (FIFO/LRU) and tracking on-disk size. Cleanup stale `run-*` dirs at startup and remove run dir on graceful exit.

3) Backfill Engine: Time-window loop: start with `cursorEnd = now`, compute `cursorStart = cursorEnd - window_days`, then `SEARCH SINCE cursorStart BEFORE cursorEnd` to retrieve UIDs (newest→oldest). Fetch RFC822 concurrently (bounded concurrency), write to cache, hand each finalized `.eml` to the existing `.eml/.emlx` parser, and delete or mark processed immediately after parser success to keep cache bounded. Stop when `cursorStart <= stop_at`, or when `max_windows` or `max_messages` reached, or when search returns empty.

Acceptance: 1) Resident cache never exceeds `max_mb` ±5% when `max_mb: 100`; 2) After successful run, run dir fully removed; 3) iCloud IMAP backfill across 3 windows ingests messages newest→older; 4) Folders with 500+ messages complete without OOM; 5) No POP code paths.
```
---

### hv-20 - EphemeralCache: run-scoped cache manager (task)

Status: **open**

Priority: **1**

```md
Create the EphemeralCache manager used by the remote IMAP collector. The manager creates a run-scoped cache directory, writes `.eml.tmp` then `rename` to `.eml`, tracks on-disk size, enforces `max_mb` via eviction of already-processed files, and removes stale runs on startup.

Deliverables: `EphemeralCache` Swift type (protocol + implementation) with methods: createRunDir, writeTemp, finalizeTemp, markProcessed, enforceSizeCap, cleanupOnExit, cleanupStaleRuns. Concurrency-safe (serial DispatchQueue or actor). Temp→rename pattern.

Acceptance: With `max_mb: 100`, cache keeps on-disk usage ≤100MB ±5%; Run dir removed after normal run; Stale dirs removed at startup; Files written via *.eml.tmp and visible after rename; Processed files deleted to maintain cap.
```
---

### hv-21 - Gateway: Provide per-account IMAP processed-state API and HostAgent integration

Status: **open**

Priority: **1**

```md
Background:
The HostAgent IMAP run currently persists per-account+folder last-processed UIDs to a local file cache under the configured `mail_imap.cache.dir`. We want the Gateway to be the single source of truth for that state so multiple HostAgent instances (or other workers) can coordinate, and to avoid local-only state that is hard to inspect or migrate.

Goal:
Add a Gateway-backed API and storage for the IMAP per-account processed-state, and update HostAgent to read/write that state from the Gateway instead of the local on-disk cache.

Scope:
1. Gateway API: Add endpoints GET /v1/imap/state and POST/PUT /v1/imap/state. Persist state in Gateway DB (new table `imap_account_state`). Add migrations and index.
2. Gateway backend: Storage adapter with unit tests for read/write semantics and auth.
3. HostAgent changes: Remove local file-based state. Call Gateway GET at run start and POST/PUT after successful submissions. Add retry/backoff/fail-safe fallback.
4. Tests & docs: Add unit tests for Gateway handlers and HostAgent changes. Update docs.

Acceptance: Gateway exposes GET/PUT endpoints; HostAgent uses Gateway endpoints; safe fallback when Gateway unavailable; tests exist; docs updated.
```
---

### hv-22 - Unit 5: Task heuristics + assignee + place merge (thread-scoped)

Status: **open**

Priority: **1**

```md
Implement conversation-aware heuristics for task detection, assignee resolution, and place entity merging within thread context
```
---

### hv-24 - Unified Collector Run API (Normalizer + Router)

Status: **open**

Priority: **1**

```md
Create a single Run API and a Normalizer+Router component in hostagent that owns `/v1/collectors/:name:run`, validates a unified JSON body, normalizes it to a shared DTO, routes to the correct collector adapter (imap, local_mail, imessage), and returns a standard response envelope.

Unified Request includes mode, limit, batch_size, order, time_window, date_range, reset, concurrency, dry_run, source_overrides, credentials.

Standard Response includes status, collector, run_id, started_at, finished_at, stats (scanned, matched, submitted, skipped, batches), warnings, errors.

Deliverables: RunRouter.swift (HTTP handler), CollectorRunRequest.swift (DTO + validation), RunResponse.swift (envelope), adapters for each collector, JSON Schema, tests.

Acceptance: Single route accepts unified body and rejects unknown fields; date_range overrides time_window; order honored; response uses standard envelope; tests pass.
```
---

### hv-25 - Tests: unit + end-to-end smoke for Run API and adapters

Status: **open**

Priority: **2**

```md
Add tests for the Collector Run API and adapters.

Tests to add:
- Unit tests for `CollectorRunRequest` decoding and schema rejections (unknown fields, bad enums).
- Table-driven unit tests for each adapter mapping (IMAP, Local, iMessage) with golden req/resp.
- Route-level end-to-end smoke tests for `/v1/collectors/:name:run` asserting standard response envelope, status, and stats.

Acceptance criteria:
- Tests added under `test/` and `tests/` as appropriate; CI should run them; provide example fixture files under `test/fixtures/collectors/`.
```
---

### hv-26 - Docs & examples: collectors_run_api.md + fixtures

Status: **open**

Priority: **2**

```md
Add documentation and example fixtures for the unified collectors Run API.

Artifacts:
- `docs/hostagent/collectors_run_api.md` with schema overview, example requests/responses, and notes about concurrency clamp and date precedence.
- Example fixtures in `test/fixtures/collectors/` (golden requests/responses for each collector and schema error examples).

Acceptance criteria:
- Docs page created and fixtures available for tests and developer reference.
```
---

### hv-28 - CI / Quality gates: run tests & fix issues for Run API

Status: **open**

Priority: **2**

```md
Run unit tests and CI checks for changes related to the unified Run API and ensure the codebase remains green.

Tasks:
- Run `pytest` and fix any failing tests introduced by the new code.
- Address linting/type errors in hostagent files touched.
- Add CI job updates if needed to include new test fixtures.
- Ensure commit messages include `Refs: beads:#haven-71` when landing PRs.

Acceptance criteria:
- Tests pass locally for the modified hostagent code; CI job(s) run and pass; any remaining failures documented with remediation steps.
```
---

### hv-29 - Test Issue

Status: **open**

Priority: **2**

```md

```
---

### hv-30 - Unit 9 (docs): README_poc.md — finalize after units 2/4/5/8

Status: **open**

Priority: **1**

```md
Final POC README with 3–4 commands to run and verification steps. This task must wait until Units 2, 4, 5, and 8 are complete.
```
---

### hv-31 - Handle long running collector jobs better

Status: **open**

Priority: **2**

```md
Long running collector jobs don't give any intermediate feedback to the caller. Think about different ways we could give the caller status or maybe do an async with a job queue
```
---

### hv-32 - Support batch submissions from hostagent to gateway

Status: **open**

Priority: **2**

```md

```
---

### hv-33 - Test Issue

Status: **open**

Priority: **2**

```md

```
---

### hv-34 - HostAgent: Make collector polling intervals configurable (iMessage, LocalFS, Contacts)

Status: **open**

Priority: **2**

```md
Add configuration and runtime controls to set polling intervals for HostAgent collectors (iMessage, LocalFS, Contacts, and any future collectors).\n\nBackground:\nHostAgent currently runs collectors on fixed schedules. Operators need the ability to tune polling frequency per-collector to balance CPU/IO, battery, and timeliness. This task adds config, runtime endpoints, and documentation.\n\nAcceptance criteria:\n- Add per-collector polling interval configuration via: 1) `hostagent.yaml` config file (per-collector keys), 2) environment variables `HOSTAGENT_<COLLECTOR>_POLL_INTERVAL_SEC`, and 3) CLI flags for simulate/test runs.\n- Implement runtime endpoints: `GET /v1/collectors/{collector}/poll_interval` and `POST /v1/collectors/{collector}/poll_interval` to view and update the interval without restart. POST accepts `{ "interval_seconds": <number> }` and validates min/max bounds.\n- Ensure iMessage, LocalFS, and Contacts collectors read the effective interval and apply it for scheduling/backoff; new collectors should reuse the same scheduling helper.\n- Validate that changes via environment, config file, and runtime API follow this precedence: API update > env var > config file > default (60s). Document this precedence in `AGENTS.md` and `hostagent/QUICKSTART.md`.
- Add unit tests for scheduling helper and integration tests that simulate changing the poll interval at runtime and confirm the collector respects the new interval within one cycle.
- Add labels: `service/hostagent`, `type/task`, `risk/low`, `priority:P2`.
\nNotes:\n- Use sensible min/max (min 5s, max 86400s = 1 day) and defensive validation.\n- Prefer a small, shared scheduling utility that emits schedule ticks and supports update at runtime and backoff.\n- Keep changes backwards compatible; default behavior remains current schedule if no config provided.\n
```
---

### hv-35 - Add Google-style docstrings and API docs generation

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

### hv-36 - MKDocs integration notes for haven-52 (docstrings + mkdocs)

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

### hv-37 - Add OpenAPI exporter endpoint to HostAgent runtime

Status: **open**

Priority: **2**

```md
Goal
Add a canonical, runtime OpenAPI exporter to the HostAgent Swift service so the service can serve its OpenAPI spec (JSON and/or YAML) and be the single source-of-truth for API docs. This will eliminate spec drift and allow automation (mkdocs/exporter) to fetch the live spec during docs builds or CI.

Background
Currently the repo contains a static `openapi/hostagent.yaml` authored by hand and a Python exporter that writes a Redoc page for it. HostAgent is a macOS-native Swift service; there is no runtime OpenAPI endpoint. That produces drift risk when new routes or request/response schemas are added in Swift.

Scope
- Add an endpoint to HostAgent that exposes the service's OpenAPI specification at `/openapi.json` and `/openapi.yaml` (YAML optional). The endpoint should be enabled in dev/build configurations and guarded behind admin or local-only access in production if required by config.
- Generate OpenAPI programmatically from the HostAgent router/handlers and bundled JSON schemas in `Resources/*/schemas/*.schema.json` (merge those into components.schemas). If full programmatic generation is infeasible, provide a build-time task that composes the OpenAPI spec from route metadata + JSON schemas and writes a file to `Resources/OpenAPI/hostagent.yaml` that the server serves statically.
- Ensure the exporter includes the Collector routes, email utilities, FSWatch, face detection, OCR, entities, modules, metrics, and health endpoints already present in the router.
- Add minimal tests that exercise the endpoint and verify the presence of key paths and the `CollectorRunRequest` schema in components.
- Update docs/dev workflow: the Python `scripts/export_openapi.py` (or docs hooks) can optionally fetch the runtime `/openapi.yaml` (if server running) or read the build-time generated `Resources/OpenAPI/hostagent.yaml` during docs builds/CI.

Design notes
- Runtime approach (preferred long-term): implement a small OpenAPI-builder utility in Swift that walks the Router/PatternRouteHandler registrations and collects path patterns, methods, and handler metadata. For each route, include a path entry with sensible default request/response schemas, and resolve component schemas by importing JSON schema files from Resources.
  - Expose endpoints: `/openapi.json` and `/openapi.yaml` (Content-Type application/json / application/x-yaml).
  - Add a config toggle: `openapi.enabled: true|false`, default true in dev, false in production unless explicitly enabled.
  - Secure the endpoint optionally with the hostagent auth header (configurable) or limit to localhost only.

- Build-time fallback (lower risk): add a Swift PackageTarget/tool that generates `Resources/OpenAPI/hostagent.yaml` from the same route discovery utility and schema files. Add a Makefile or SPM run target `swift run hostagent-openapi --emit-resources` to write the file into `Resources/OpenAPI/` which will be bundled and served as static files.

Acceptance criteria
- The HostAgent binary serves an OpenAPI spec at `/openapi.yaml` when `openapi.enabled` is true (or the generated resource file exists). The spec includes paths for collectors (including `imessage` and `email_imap`) and contains `components.schemas.CollectorRunRequest` matching the JSON schema in `Resources/Collectors/schemas/collector_run_request.schema.json`.
- Unit/integration test that makes a local request to `/openapi.yaml` and asserts the spec contains `/v1/collectors/imessage:run` and `components.schemas.CollectorRunRequest`.
- `scripts/export_openapi.py` can optionally be updated to fetch the runtime `/openapi.yaml` (if server available) during docs builds — documented in the README/dev docs.

Implementation tasks
1. Add a new Swift module `HostOpenAPI` or utility inside HostAgent to build the spec.
2. Implement route-walker that introspects `Router` / `PatternRouteHandler` registrations.
3. Merge JSON schemas from `Resources/**/schemas/*.schema.json` into `components.schemas`.
4. Expose endpoints `/openapi.json` and `/openapi.yaml` (serve YAML by converting internal JSON using a YAML serializer or pre-generate YAML at build time).
5. Add config flag to enable/disable endpoint and optional local-only/auth restrictions.
6. Add tests covering presence of key paths and schemas.
7. Optional: update `scripts/export_openapi.py` doc/comments to support fetching runtime spec.

Notes / Risks
- Programmatic route introspection in Swift depends on the router implementation. If introspection is not possible, the build-time generator fallback will be used.
- Care must be taken to not leak sensitive data (authentication headers, internal endpoints). Default to local-only in production.

Estimate
- Design + prototype: 1–2 days
- Implementation + tests + docs: 2–4 days


```
---

### hv-38 - hostagent: validate & consolidate hostagent.yaml format

Status: **open**

Priority: **2**

```md
Double-check, clean up, and consolidate the `hostagent.yaml` configuration format used by HostAgent. This task will: 1) review the current `.tmp/hostagent.bak.yaml` (provided by user) and any other hostagent config examples; 2) produce a single canonical `hostagent.yaml` schema (keys, types, defaults); 3) merge and clean duplicate/legacy keys; 4) add simple validation (schema or unit tests) and update docs so other contributors follow the canonical format.
```
---

### hv-44 - Tests: unit + end-to-end smoke for Run API and adapters

Status: **open**

Priority: **2**

```md
Add tests for the Collector Run API and adapters.

Tests to add:
- Unit tests for `CollectorRunRequest` decoding and schema rejections (unknown fields, bad enums).
- Table-driven unit tests for each adapter mapping (IMAP, Local, iMessage) with golden req/resp.
- Route-level end-to-end smoke tests for `/v1/collectors/:name:run` asserting standard response envelope, status, and stats.

Acceptance criteria:
- Tests added under `test/` and `tests/` as appropriate; CI should run them; provide example fixture files under `test/fixtures/collectors/`.

```
---

### hv-45 - Docs & examples: collectors_run_api.md + fixtures

Status: **open**

Priority: **2**

```md
Add documentation and example fixtures for the unified collectors Run API.

Artifacts:
- `docs/hostagent/collectors_run_api.md` with schema overview, example requests/responses, and notes about concurrency clamp and date precedence.
- Example fixtures in `test/fixtures/collectors/` (golden requests/responses for each collector and schema error examples).

Acceptance criteria:
- Docs page created and fixtures available for tests and developer reference.

```
---

### hv-46 - Clamp concurrency centrally in normalizer/DTO

Status: **open**

Priority: **2**

```md
Implement central concurrency clamp (1..12) in the `CollectorRunRequest` normalizer so all adapters inherit the limit.

Tasks:
- Enforce clamp during decode/normalization; if out of range, clamp and log a warning; tests for values <1 and >12.
- Document behavior in `docs/hostagent/collectors_run_api.md`.

Acceptance criteria:
- Concurrency values are clamped and unit tests verify clamping and warning emission.

```
---

### hv-47 - CI / Quality gates: run tests & fix issues for Run API

Status: **open**

Priority: **2**

```md
Run unit tests and CI checks for changes related to the unified Run API and ensure the codebase remains green.

Tasks:
- Run `pytest` and fix any failing tests introduced by the new code.
- Address linting/type errors in hostagent files touched.
- Add CI job updates if needed to include new test fixtures.
- Ensure commit messages include `Refs: beads:#haven-71` when landing PRs.

Acceptance criteria:
- Tests pass locally for the modified hostagent code; CI job(s) run and pass; any remaining failures documented with remediation steps.

```
---

### hv-49 - Hostagent: Port macOS Contacts collector (collector_contacts.py) to Swift

Status: **open**

Priority: **2**

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

### hv-61 - Remove legacy local mail collector code

Status: **open**

Priority: **2**

```md
Delete all local mail collector implementation files, tests, and documentation. Clean up package dependencies and remove deprecated configuration fields. IMAP-only mail collection after this change.
```
---

### hv-62 - POC: Hostagent → Gateway → Neo4j (Life Graph)

Status: **open**

```md
Stand up Neo4j in compose, add Gateway POC routes, call Hostagent for iMessage crawl (N/X days), run native extraction & merges, idempotent upsert to Neo4j, provide validation queries.
```
---

### hv-63 - Publish Docs with MkDocs + Material

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

### hv-64 - Add Google-style docstrings and API docs generation

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

### hv-65 - MKDocs integration notes for haven-52 (docstrings + mkdocs)

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

### hv-66 - Remote IMAP Email Collector (epic): ephemeral .eml backfill & run-scoped cache

Status: **open**

Priority: **1**

```md
Implement an IMAP-based remote collector (MailCore 2) that streams RFC822 bytes to ephemeral .eml files while running, hands them to the existing hostagent .eml/.emlx parser, and deletes the cache directory on exit. Support timeframe-batched backfill (newest→older windows). No POP support.

Size: XL
```
---

### hv-67 - ImapSession: MailCore2 async wrapper (task)

Status: **open**

Priority: **1**

```md
Implement an async Swift wrapper `ImapSession` around MailCore 2 (`MCOIMAPSession`) that exposes two primary async methods and pluggable auth for XOAUTH2 and app passwords.

Deliverables:
- `ImapSession` Swift type with:
  - `searchMessages(folder: String, since: Date?, before: Date?) async throws -> [UInt32]` — returns UIDs ordered newest→oldest.
  - `fetchRFC822(folder: String, uid: UInt32) async throws -> Data` — returns full RFC822 bytes.
- Auth support: XOAUTH2 and app-password; secrets resolved via Keychain `secret_ref` (no logging of secrets).
- Concurrency-safe implementation suitable for use by BackfillEngine; configurable concurrency limit for fetches.
- Unit tests covering search -> fetch flow (mocked MailCore session), error handling, and retry/backoff behaviour for transient network errors.
- Integration example in `hostagent` showing how to call `ImapSession` and fetch a single UID.

Acceptance criteria:
- `searchMessages` and `fetchRFC822` implemented and documented in code comments.
- Unit tests exist and pass locally (mocked MailCore responses).
- The implementation exposes a clear interface usable by `BackfillEngine` and handles auth via Keychain refs.
- No POP code paths are added.

Notes:
- Prefer Swift concurrency (async/await) and structured concurrency for parallel fetches.
- Use safe temporary Data handling; avoid holding large bodies in memory longer than necessary (stream into cache manager when feasible).

```
---

### hv-68 - Unit 9 (docs): README_poc.md — finalize after units 2/4/5/8

Status: **open**

Priority: **1**

```md
Final POC README with 3–4 commands to run and verification steps. This task must wait until Units 2, 4, 5, and 8 are complete.
```
---

### hv-69 - EphemeralCache: run-scoped cache manager (task)

Status: **open**

Priority: **1**

```md
Create the EphemeralCache manager used by the remote IMAP collector. The manager creates a run-scoped cache directory, writes `.eml.tmp` then `rename` to `.eml`, tracks on-disk size, enforces `max_mb` via eviction of already-processed files, and removes stale runs on startup.
```
---

### hv-70 - Gateway: Provide per-account IMAP processed-state API and HostAgent integration

Status: **open**

Priority: **1**

```md
Background

The HostAgent IMAP run currently persists per-account+folder last-processed UIDs to a local file cache under the configured `mail_imap.cache.dir`. We want the Gateway to be the single source of truth for that state so multiple HostAgent instances (or other workers) can coordinate, and to avoid local-only state that is hard to inspect or migrate.

Goal

Add a Gateway-backed API and storage for the IMAP per-account processed-state, and update HostAgent to read/write that state from the Gateway instead of the local on-disk cache.

Scope / Implementation notes

1. Gateway API
   - Add endpoints:
     - GET /v1/imap/state?account_id={id}&folder={folder} -> {"last_processed_uid": <int>, "updated_at": "<iso>"}
     - POST/PUT /v1/imap/state -> {account_id, folder, last_processed_uid} (idempotent write)
   - Validate Bearer token (existing Gateway auth middleware) and require internal service token for writes.
   - Persist state in Gateway DB (new table `imap_account_state`): columns: account_id (text), folder (text), last_processed_uid (integer), updated_at (timestamp), updated_by (optional).
   - Add simple migrations and an index on (account_id, folder).

2. Gateway backend
   - Storage adapter in gateway service (catalog or a small new DB table via existing DB layer).
   - Unit tests for read/write semantics and auth.

3. HostAgent changes
   - Remove use of local file-based state for IMAP runs.
   - On IMAP run start, call Gateway GET to fetch last_processed_uid for account+folder.
   - After each successful submission (or at end of run), call Gateway POST/PUT to update last_processed_uid with the latest processed UID.
   - Add retry/backoff/fail-safe: if Gateway call fails, HostAgent should log warning and fall back to treating last_processed_uid as 0 (to avoid losing messages) and continue processing — but not clobber remote state on write errors.

4. Tests & docs
   - Add unit tests for Gateway handlers and HostAgent changes (mock HTTP client in HostAgent tests).
   - Update `docs/hostagent/email-imap-collector.md` to reflect new behavior and configuration.

Acceptance criteria

- Gateway exposes documented GET/PUT endpoints for IMAP account state and persistently stores state in DB with an index.
- HostAgent no longer writes/reads per-account IMAP state to local files; instead, it uses the Gateway endpoints.
- HostAgent includes a safe fallback when Gateway is unreachable (logs and continues without overwriting remote state).
- Tests exist covering read/write path and a HostAgent test mocking the Gateway API.
- Docs updated describing the behavior and required Gateway token permissions.

Notes / Risks

- Risk: introducing a single point of failure if Gateway is unavailable; mitigations described above.
- Backfill/migration: existing local cache files won't be auto-migrated; include a follow-up task to migrate existing local state (optional).

```
---

### hv-71 - Extract clean email body text and image captions (strip MIME/HTML cruft)

Status: **open**

Priority: **1**

```md
Problem: Ingested emails currently carry raw MIME/html bodies which include styling, quoted replies, signatures, and other cruft. We need a standardized extraction that captures the meaningful plain-text body and any image captions so downstream indexing/embeddings are higher quality.

Goal: Implement an extractor that, for each submitted email, produces a cleaned plain-text body and a list of image captions (sourced from alt attributes, <figcaption>, adjacent text, or OCR on attached images as an opt-in step). The extractor should run in the ingestion pipeline so the Catalog stores the cleaned body and captions (not the raw html/mime) alongside existing metadata.

Design notes:
- Parse MIME with Python's email library to identify parts.
- Prefer text/plain. If missing, convert html -> text using a reliable converter (e.g., html2text or bleach + lxml text extraction) and remove boilerplate and inline CSS.
- Strip quoted reply/forward blocks using heuristics (common separators like "On .* wrote:", lines starting with ">", and HTML elements with classes/ids commonly used for quoted text).
- Extract image captions:
  - from <img alt="..."> attributes
  - from <figure><figcaption>...</figcaption></figure>
  - from text nodes immediately preceding/following img nodes
  - as an optional worker stage: run OCR on image attachments (controlled by feature flag) and include OCR text as a caption with source="ocr" if no alt/caption found
- Preserve language metadata and avoid dropping meaningful whitespace or non-latin scripts.
- Keep it idempotent and safe: do not modify stored original payloads. Add new fields to the document/chunk model as needed (e.g., cleaned_body, image_captions).

Acceptance criteria:
1) Unit tests: for text/plain, html-only, multipart with inline images (alt + figcaption), and quoted-reply stripping.
2) Integration test: ingest sample email fixture and verify Catalog (or document record) contains cleaned plain-text snippet and image_captions list.
3) No changes to original raw MIME payload stored elsewhere. The new fields are additive.
4) Feature flag or env var to enable/disable OCR (DEFAULT: disabled).

Implementation plan (next steps):
- Add shared parsing utility in `shared/email_parsing.py` (or existing email utilities) with small functions: parse_mime_parts, html_to_text, strip_quoted, extract_image_captions.
- Hook into gateway ingestion pipeline to call the extractor before creating document/chunk records.
- Add unit + integration tests under `test/` using existing fixtures.
- Add env/config: ENABLE_IMAGE_OCR (false) and doc note.

Notes:
- Risk: medium (affects ingestion pipeline). Keep changes additive and behind flag if needed.
```
---

### hv-72 - haven-XX: Unified Collector Run API (Normalizer + Router)

Status: **open**

Priority: **1**

```md
Create a single Run API and a Normalizer+Router component in hostagent that owns `/v1/collectors/:name:run`, validates a unified JSON body, normalizes it to a shared DTO, routes to the correct collector adapter (imap, local_mail, imessage), and returns a standard response envelope.

No legacy/transition support.

Unified Request (all collectors):

{
  "mode": "run|dry_run|tail|backfill",
  "limit": 0,
  "batch_size": 500,
  "order": "asc|desc",
  "time_window": { "lookback_days": 30, "thread_lookback_days": 90 },
  "date_range": { "since": "2025-01-01T00:00:00Z", "until": "2025-02-01T00:00:00Z" },
  "reset": false,
  "concurrency": 4,
  "dry_run": false,
  "source_overrides": {},
  "credentials": { "kind": "", "secret": "", "secret_ref": "" }
}

Standard Response:

{
  "status": "ok|error|partial",
  "collector": "imessage|email_imap|email_local",
  "run_id": "…",
  "started_at": "…",
  "finished_at": "…",
  "stats": {
    "scanned": 0, "matched": 0, "submitted": 0, "skipped": 0,
    "earliest_touched": "…", "latest_touched": "…", "batches": 0
  },
  "warnings": [], "errors": []
}

Deliverables:
- hostagent/Collectors/RunRouter.swift — HTTP handler for /v1/collectors/:name:run; validates → normalizes → routes.
- hostagent/Collectors/CollectorRunRequest.swift — shared DTO + JSON decoding + schema validation.
- hostagent/Collectors/RunResponse.swift — standard response envelope + timing helpers.

Adapters:
- ImapRunAdapter.swift → maps to ImapRunRequest (supports: account_id, folder, max_limit, before; concurrency, reset, dry_run).
- LocalMailRunAdapter.swift → maps to Local RunRequest (supports: source_path; order/since/until; dry_run→simulate).
- IMessageRunAdapter.swift → maps to iMessage params; supports optional date_range + order, thread_lookback_days.
- schemas/collector_run_request.schema.json — JSON Schema for request validation.
- Tests: golden req/resp for each collector + failure cases (schema errors, invalid enums).

Acceptance Criteria:
1. A single route /v1/collectors/:name:run accepts only the unified body and rejects unknown fields.
2. If date_range present, it overrides time_window selection semantics.
3. order honored by IMAP/Local and by iMessage (default DESC when not provided).
4. Response uses the standard envelope for all collectors with accurate stats and timings.
5. Unit tests pass; end-to-end smoke tests succeed for each collector.

Non-goals: No legacy field parsing, no deprecation layer, no client-side shims.

Implementation Plan:
1. Schema & DTO: Add JSON Schema; implement CollectorRunRequest with strict decoding (fail on unknowns).
2. Router: Implement RunRouter to parse collector name, validate body, build DTO, and dispatch to adapter.
3. Adapters:
   • IMAP: map unified → ImapRunRequest; compute since from lookback_days if no date_range.
   • Local: map unified → Local RunRequest; dry_run triggers simulate path if source_path provided.
   • iMessage: extend handler to accept optional since/until + order, else fall back to lookbacks.
4. Response: Normalize each handler’s result into RunResponse; include durations and batch counts.
5. Tests: Table-driven tests per adapter; schema rejection tests; end-to-end route tests.

Notes:
- Keep concurrency clamped (1..12) centrally in the normalizer.
- Use ISO-8601 UTC for all timestamps.

```
---

### hv-73 - Tests: unit + end-to-end smoke for Run API and adapters

Status: **open**

Priority: **2**

```md
Add tests for the Collector Run API and adapters.

Tests to add:
- Unit tests for `CollectorRunRequest` decoding and schema rejections (unknown fields, bad enums).
- Table-driven unit tests for each adapter mapping (IMAP, Local, iMessage) with golden req/resp.
- Route-level end-to-end smoke tests for `/v1/collectors/:name:run` asserting standard response envelope, status, and stats.

Acceptance criteria:
- Tests added under `test/` and `tests/` as appropriate; CI should run them; provide example fixture files under `test/fixtures/collectors/`.

```
---

### hv-74 - Docs & examples: collectors_run_api.md + fixtures

Status: **open**

Priority: **2**

```md
Add documentation and example fixtures for the unified collectors Run API.

Artifacts:
- `docs/hostagent/collectors_run_api.md` with schema overview, example requests/responses, and notes about concurrency clamp and date precedence.
- Example fixtures in `test/fixtures/collectors/` (golden requests/responses for each collector and schema error examples).

Acceptance criteria:
- Docs page created and fixtures available for tests and developer reference.

```
---

### hv-75 - Clamp concurrency centrally in normalizer/DTO

Status: **open**

Priority: **2**

```md
Implement central concurrency clamp (1..12) in the `CollectorRunRequest` normalizer so all adapters inherit the limit.

Tasks:
- Enforce clamp during decode/normalization; if out of range, clamp and log a warning; tests for values <1 and >12.
- Document behavior in `docs/hostagent/collectors_run_api.md`.

Acceptance criteria:
- Concurrency values are clamped and unit tests verify clamping and warning emission.

```
---

### hv-76 - CI / Quality gates: run tests & fix issues for Run API

Status: **open**

Priority: **2**

```md
Run unit tests and CI checks for changes related to the unified Run API and ensure the codebase remains green.

Tasks:
- Run `pytest` and fix any failing tests introduced by the new code.
- Address linting/type errors in hostagent files touched.
- Add CI job updates if needed to include new test fixtures.
- Ensure commit messages include `Refs: beads:#haven-71` when landing PRs.

Acceptance criteria:
- Tests pass locally for the modified hostagent code; CI job(s) run and pass; any remaining failures documented with remediation steps.

```
---

### hv-77 - Epic: Finish Hostagent — build, run, test, and integrate

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

### hv-78 - Epic: Finish Hostagent — build, run, test, and integrate

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

### hv-79 - hostagent: validate & consolidate hostagent.yaml format

Status: **open**

Priority: **2**

```md
Double-check, clean up, and consolidate the `hostagent.yaml` configuration format used by HostAgent. This task will: 1) review the current `.tmp/hostagent.bak.yaml` (provided by user) and any other hostagent config examples; 2) produce a single canonical `hostagent.yaml` schema (keys, types, defaults); 3) merge and clean duplicate/legacy keys; 4) add simple validation (schema or unit tests) and update docs so other contributors follow the canonical format.
```
---

### hv-80 - Add OpenAPI exporter endpoint to HostAgent runtime

Status: **open**

Priority: **2**

```md
Goal
Add a canonical, runtime OpenAPI exporter to the HostAgent Swift service so the service can serve its OpenAPI spec (JSON and/or YAML) and be the single source-of-truth for API docs. This will eliminate spec drift and allow automation (mkdocs/exporter) to fetch the live spec during docs builds or CI.

Background
Currently the repo contains a static `openapi/hostagent.yaml` authored by hand and a Python exporter that writes a Redoc page for it. HostAgent is a macOS-native Swift service; there is no runtime OpenAPI endpoint. That produces drift risk when new routes or request/response schemas are added in Swift.

Scope
- Add an endpoint to HostAgent that exposes the service's OpenAPI specification at `/openapi.json` and `/openapi.yaml` (YAML optional). The endpoint should be enabled in dev/build configurations and guarded behind admin or local-only access in production if required by config.
- Generate OpenAPI programmatically from the HostAgent router/handlers and bundled JSON schemas in `Resources/*/schemas/*.schema.json` (merge those into components.schemas). If full programmatic generation is infeasible, provide a build-time task that composes the OpenAPI spec from route metadata + JSON schemas and writes a file to `Resources/OpenAPI/hostagent.yaml` that the server serves statically.
- Ensure the exporter includes the Collector routes, email utilities, FSWatch, face detection, OCR, entities, modules, metrics, and health endpoints already present in the router.
- Add minimal tests that exercise the endpoint and verify the presence of key paths and the `CollectorRunRequest` schema in components.
- Update docs/dev workflow: the Python `scripts/export_openapi.py` (or docs hooks) can optionally fetch the runtime `/openapi.yaml` (if server running) or read the build-time generated `Resources/OpenAPI/hostagent.yaml` during docs builds/CI.

Design notes
- Runtime approach (preferred long-term): implement a small OpenAPI-builder utility in Swift that walks the Router/PatternRouteHandler registrations and collects path patterns, methods, and handler metadata. For each route, include a path entry with sensible default request/response schemas, and resolve component schemas by importing JSON schema files from Resources.
  - Expose endpoints: `/openapi.json` and `/openapi.yaml` (Content-Type application/json / application/x-yaml).
  - Add a config toggle: `openapi.enabled: true|false`, default true in dev, false in production unless explicitly enabled.
  - Secure the endpoint optionally with the hostagent auth header (configurable) or limit to localhost only.

- Build-time fallback (lower risk): add a Swift PackageTarget/tool that generates `Resources/OpenAPI/hostagent.yaml` from the same route discovery utility and schema files. Add a Makefile or SPM run target `swift run hostagent-openapi --emit-resources` to write the file into `Resources/OpenAPI/` which will be bundled and served as static files.

Acceptance criteria
- The HostAgent binary serves an OpenAPI spec at `/openapi.yaml` when `openapi.enabled` is true (or the generated resource file exists). The spec includes paths for collectors (including `imessage` and `email_imap`) and contains `components.schemas.CollectorRunRequest` matching the JSON schema in `Resources/Collectors/schemas/collector_run_request.schema.json`.
- Unit/integration test that makes a local request to `/openapi.yaml` and asserts the spec contains `/v1/collectors/imessage:run` and `components.schemas.CollectorRunRequest`.
- `scripts/export_openapi.py` can optionally be updated to fetch the runtime `/openapi.yaml` (if server available) during docs builds — documented in the README/dev docs.

Implementation tasks
1. Add a new Swift module `HostOpenAPI` or utility inside HostAgent to build the spec.
2. Implement route-walker that introspects `Router` / `PatternRouteHandler` registrations.
3. Merge JSON schemas from `Resources/**/schemas/*.schema.json` into `components.schemas`.
4. Expose endpoints `/openapi.json` and `/openapi.yaml` (serve YAML by converting internal JSON using a YAML serializer or pre-generate YAML at build time).
5. Add config flag to enable/disable endpoint and optional local-only/auth restrictions.
6. Add tests covering presence of key paths and schemas.
7. Optional: update `scripts/export_openapi.py` doc/comments to support fetching runtime spec.

Notes / Risks
- Programmatic route introspection in Swift depends on the router implementation. If introspection is not possible, the build-time generator fallback will be used.
- Care must be taken to not leak sensitive data (authentication headers, internal endpoints). Default to local-only in production.

Estimate
- Design + prototype: 1–2 days
- Implementation + tests + docs: 2–4 days


```
---

### hv-81 - Hostagent: Port macOS Contacts collector (collector_contacts.py) to Swift

Status: **open**

Priority: **2**

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

### hv-82 - HostAgent: Make collector polling intervals configurable (iMessage, LocalFS, Contacts)

Status: **open**

Priority: **2**

```md
Add configuration and runtime controls to set polling intervals for HostAgent collectors (iMessage, LocalFS, Contacts, and any future collectors).\n\nBackground:\nHostAgent currently runs collectors on fixed schedules. Operators need the ability to tune polling frequency per-collector to balance CPU/IO, battery, and timeliness. This task adds config, runtime endpoints, and documentation.\n\nAcceptance criteria:\n- Add per-collector polling interval configuration via: 1) `hostagent.yaml` config file (per-collector keys), 2) environment variables `HOSTAGENT_<COLLECTOR>_POLL_INTERVAL_SEC`, and 3) CLI flags for simulate/test runs.\n- Implement runtime endpoints: `GET /v1/collectors/{collector}/poll_interval` and `POST /v1/collectors/{collector}/poll_interval` to view and update the interval without restart. POST accepts `{ "interval_seconds": <number> }` and validates min/max bounds.\n- Ensure iMessage, LocalFS, and Contacts collectors read the effective interval and apply it for scheduling/backoff; new collectors should reuse the same scheduling helper.\n- Validate that changes via environment, config file, and runtime API follow this precedence: API update > env var > config file > default (60s). Document this precedence in `AGENTS.md` and `hostagent/QUICKSTART.md`.
- Add unit tests for scheduling helper and integration tests that simulate changing the poll interval at runtime and confirm the collector respects the new interval within one cycle.
- Add labels: `service/hostagent`, `type/task`, `risk/low`, `priority:P2`.
\nNotes:\n- Use sensible min/max (min 5s, max 86400s = 1 day) and defensive validation.\n- Prefer a small, shared scheduling utility that emits schedule ticks and supports update at runtime and backoff.\n- Keep changes backwards compatible; default behavior remains current schedule if no config provided.\n
```
---

### hv-83 - Compile MailCore2 for Apple Silicon (ARM64) support

Status: **open**

Priority: **2**

```md
Remove the requirement for `arch -x86_64` prefixes by compiling MailCore2 with native ARM64 support or finding an ARM64-compatible alternative.

## Problem
The current MailCore2 dependency (`https://github.com/MailCore/mailcore2.git`) only ships as an x86_64 framework, requiring all Swift build/test commands to use `arch -x86_64` prefix. This creates:
- Performance overhead from Rosetta translation
- Complex development workflow with architecture prefixes
- Potential CI/CD complications
- Poor developer experience on Apple Silicon Macs

## Current Workaround
All build commands in `hostagent/Makefile` use `arch -x86_64`:
```makefile
build:
	arch -x86_64 swift build
test:
	arch -x86_64 swift test
```

## Goals
- Enable native ARM64 compilation of hostagent
- Remove `arch -x86_64` prefixes from Makefile
- Maintain full IMAP functionality (search, fetch, auth)
- Improve developer experience and performance

## Implementation Options

### Option 1: Fork and Build MailCore2 for ARM64
- Fork the MailCore2 repository
- Add ARM64 build configuration
- Update Package.swift to use the forked version
- Test IMAP functionality thoroughly

### Option 2: Find ARM64-Compatible Alternative
- Research alternative Swift IMAP libraries with ARM64 support
- Evaluate compatibility with existing ImapSession implementation
- Migrate if suitable alternative found

### Option 3: Build MailCore2 from Source
- Investigate building MailCore2 from source with ARM64 support
- Create build scripts for ARM64 compilation
- Package as local dependency

## Acceptance Criteria
1. `swift build` and `swift test` work without `arch -x86_64` prefix on Apple Silicon
2. All IMAP functionality (searchMessages, fetchRFC822) works on native ARM64
3. Makefile updated to remove architecture prefixes
4. Documentation updated to remove Rosetta requirements
5. CI/CD pipelines work without architecture workarounds
6. Performance is equal or better than Rosetta-based builds

## Testing
- Verify IMAP search and fetch operations work correctly
- Test with real IMAP servers (iCloud, Gmail)
- Ensure XOAUTH2 and app-password auth still function
- Run full test suite on ARM64
- Performance benchmarking vs Rosetta builds

## Documentation Updates
- Update `docs/hostagent/email-imap-collector.md` to remove Rosetta requirements
- Update `hostagent/README.md` build instructions
- Update any CI/CD documentation

## Risks
- MailCore2 ARM64 build may have compatibility issues
- Alternative libraries may lack required features
- Breaking changes in IMAP functionality
- Increased build complexity

## Dependencies
- None (can be worked on independently)

## Notes
- Current ImapSession implementation is well-tested and should be preserved
- Consider creating a compatibility layer if switching libraries
- May need to update Package.resolved and dependency management
```
---

