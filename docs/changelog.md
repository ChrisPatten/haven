# Changelog

## 2025-01-XX — Conversational search with LLM-driven query translation
- Added `POST /v1/search/converse` endpoint for natural language search queries with automatic facet inference
- Added `POST /v1/search/facets` endpoint for discovering available facets without executing full search
- Implemented search planner using LLM to translate questions into structured queries with inferred filters (people, source_type, date ranges)
- Added context expansion for iMessage hits with surrounding messages from the same thread (8h lookback, 2h lookahead)
- Implemented facet aggregation with counts and selected state tracking for UI filter chips
- Added conversation store for maintaining filter state across multiple queries (24h TTL)
- Enhanced gateway to preserve original metadata structure when extracted from headers (supports iMessage metadata preservation)
- Updated OpenAPI specification with new conversational search endpoints and request/response models
- Added comprehensive tests for gateway metadata preservation and conversational search components

## 2025-01-XX — Rollback endpoint for data recovery
- Added `DELETE /v1/catalog/documents/rollback` endpoint to catalog service
- Enables deletion of documents added after a specified date with configurable date field (`created_at`, `ingested_at`, or `content_timestamp`)
- Automatically cleans up orphaned threads and chunks after document deletion
- Deletes `ingest_submissions` records to allow re-ingestion with same idempotency_key
- Supports use case: rollback documents with bad metadata, then re-run collector to re-ingest with correct metadata

## 2025-11-02 — People normalization and relationship intelligence
- Documented people normalization system including `people`, `person_identifiers`, `document_people` tables.
- Added `PeopleRepository` and `PeopleResolver` API documentation with usage examples.
- Documented self-person detection feature (hv-60) with MIME charset support.
- Documented CRM relationship schema (hv-61) including `crm_relationships` table structure and indexes.
- Added relationship feature aggregation documentation (hv-62) with scoring algorithm details.
- Updated contacts collector documentation to reflect Swift port (hv-8) and VCF import capabilities.
- Added `/search/people` endpoint to API documentation.
- Updated functional guide with people search and relationship workflows.
- Enhanced architecture overview to include people normalization in data flow.

## 2025-01-XX — Documentation reorganization
- Removed references to AGENTS.md and HostAgent HTTP API documentation
- Created comprehensive configuration reference documentation
- Reorganized collector documentation into dedicated guides
- Updated terminology to use "Haven.app" consistently
- Removed HostAgent HTTP API references (collectors now run directly in Haven.app)
- Updated mkdocs.yml with new documentation structure

## 2025-10-21 — Documentation consolidation (haven-50)
- Promoted legacy documentation (`README.md`, `AGENTS.md`, `documentation/*`) into the MkDocs site.
- Rewrote architecture, operations, and HostAgent landing pages with production-ready guidance.
- Linked Gateway API docs to the OpenAPI exporter workflow and documented interactive reference regeneration.
- Established docs-as-code workflow guidance (`docs/contributing.md`) and added a local preview quick start.

## 2025-10-21 — MkDocs foundation (haven-40, haven-42–45)
- Added Material-themed MkDocs site, nav skeleton, and hooks for copying OpenAPI specs.
- Introduced CI publish workflow and OpenAPI validation.

_Earlier milestones are documented in the corresponding Beads issues._
