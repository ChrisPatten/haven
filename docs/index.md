# Haven Documentation Staging

This staging tree gathers the current Haven documentation so it can be reviewed and promoted into the permanent `/docs/` directory. Each section links to the copied sources with short descriptions to guide reviewers.

## Getting Started & Guides
- [Getting Started](getting-started.md) — local preview workflow and contribution basics.
- [Repository README](guides/README.md) — project overview, development tooling, and repo conventions.
- [Agents Overview](guides/AGENTS.md) — topology and operational notes for Haven agents.

## Architecture
- [Architecture Overview](architecture/overview.md) — system context, data flow, and key components.
- [Services Deep Dive](architecture/services.md) — service-by-service breakdown with interfaces.

## Operations
- [Local Development](operations/local-dev.md) — compose profiles, environment variables, and bootstrap steps.
- [Deployment Outline](operations/deploy.md) — high-level runbook for shipping Haven services.

## HostAgent
- [HostAgent Landing](hostagent/index.md) — staging page for macOS agent documentation.
- [HostAgent README](hostagent/hostagent-readme.md) — install, launchd, and capability references from the native project.

## API
- [Gateway API Reference](api/gateway.md) — current notes on Gateway endpoints and usage.
- [API Index](api/index.md) — placeholder for the future interactive reference.

## Reference Material
- [Functional Guide](reference/functional_guide.md) — product behaviour and user workflows.
- [Technical Reference](reference/technical_reference.md) — in-depth details on internal systems.
- [Graph Reference](reference/graph.md) — data model notes for graph integrations.
- [Backup & Restore](reference/BACKUP_RESTORE.md) — procedures for snapshotting and recovery.
- [Schema v2 Reference](reference/SCHEMA_V2_REFERENCE.md) — catalog schema documentation.

## Schema Files
- [Database Init SQL](schema/init.sql) — canonical schema bootstrap script.
- [Migration README](schema/migrations/README.md) — guidance for crafting migrations.
- [Migration v2_001](schema/migrations/v2_001_email_collector.sql) — sample migration for the email collector.

## Changelog & Contributing
- [Changelog](changelog.md) — running log of noteworthy changes.
- [Contributing](contributing.md) — standards for collaborating on the docs.

## Next Steps
- Run `mkdocs serve -f mkdocs.yml --docs-dir .tmp/docs` to preview this staging tree.
- Track gaps or TODOs directly in `haven-49` before promoting content into `/docs/`.
