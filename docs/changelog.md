# Changelog

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

## 2025-10-21 — Documentation consolidation (haven-50)
- Promoted legacy documentation (`README.md`, `AGENTS.md`, `documentation/*`) into the MkDocs site.
- Rewrote architecture, operations, and HostAgent landing pages with production-ready guidance.
- Linked Gateway API docs to the OpenAPI exporter workflow and documented interactive reference regeneration.
- Established docs-as-code workflow guidance (`docs/contributing.md`) and added a local preview quick start.

## 2025-10-21 — MkDocs foundation (haven-40, haven-42–45)
- Added Material-themed MkDocs site, nav skeleton, and hooks for copying OpenAPI specs.
- Introduced CI publish workflow and OpenAPI validation.

_Earlier milestones are documented in the corresponding Beads issues._
