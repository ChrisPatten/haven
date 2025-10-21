# Contributing to Documentation

Thank you for helping improve Haven’s documentation. We treat docs as code: every change is tracked in Beads, reviewed like a feature, and published through the MkDocs pipeline.

## Before You Start
- Reference an open Beads issue (or create one) that captures scope, audience, and acceptance criteria.
- Sync `main`, create a feature branch, and run `mkdocs serve` locally for fast iteration.
- Install tooling listed in [Getting Started](getting-started.md) if you have not already (Python requirements, Docker for verification, MkDocs dependencies).

## Style and Structure
- Use task-focused headings and short paragraphs. Prefer active voice and descriptive link text.
- Reuse existing terminology (Gateway, Catalog, HostAgent) and keep API examples aligned with `openapi/gateway.yaml`.
- When copying snippets verbatim from another file, add a brief attribution or link in the surrounding text.
- Group reference material under the appropriate IA section (Guides, Architecture, Operations, HostAgent, API, Reference, Schema).

## Workflow
1. Draft changes in your feature branch.
2. Preview locally:
   ```bash
   mkdocs serve
   ```
   Validate navigation, cross-links, code fences, and OpenAPI download buttons.
3. Run formatting and tests relevant to your change (e.g., `ruff`, `black --check`, `pytest` if you touched code samples or scripts).
4. Commit with a message that references the Beads issue (e.g., `Docs: refresh architecture overview (Refs: beads:#haven-50)`).
5. Open a pull request, include screenshots if the visual layout changed, and request review from the docs maintainers.

## Review Checklist
- [ ] Content matches current product behaviour and configuration.
- [ ] Links resolve and code snippets execute as written (or note any prerequisites).
- [ ] OpenAPI references and CLI examples use the latest flags/paths.
- [ ] MkDocs navigation reflects new pages or renamed files.
- [ ] Changelog updated when changes are user-visible.

After approval, merge into `main`; the CI workflow builds and publishes the site automatically. Follow up with additional issues if the work uncovers new documentation gaps.

_Adapted from `.tmp/docs/index.md`, repository contribution notes, and MkDocs workflow guidance._
