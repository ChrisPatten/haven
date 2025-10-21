# Haven Documentation

Haven is a personal data plane that keeps high-signal conversations, files, and local knowledge searchable without leaving your device. These pages collect the canonical runbooks, architecture notes, and API references that previously lived across `README.md`, `AGENTS.md`, and the legacy `documentation/` tree.

## Start Here
- [Getting Started](getting-started.md) — install prerequisites, run the stack locally, and preview docs.
- [Repository Overview](guides/README.md) — tour of the source tree, collectors, and shared tooling.
- [Agents Overview](guides/AGENTS.md) — HostAgent topology, orchestration rules, and runbooks.

## How the Platform Fits Together
- [Architecture Overview](architecture/overview.md) — system context, data flow, and critical data stores.
- [Service Deep Dive](architecture/services.md) — responsibilities and interfaces for each core service.
- [Technical Reference](reference/technical_reference.md) — detailed schema, ingestion, and pipeline behaviour.

## Operating Haven
- [Local Development](operations/local-dev.md) — compose profiles, environment variables, and verification steps.
- [Deployment](operations/deploy.md) — promote builds, run migrations, and validate production rollouts.
- [HostAgent Landing](hostagent/index.md) — macOS-specific setup, permissions, and troubleshooting.

## APIs and References
- [Gateway API](api/gateway.md) — download and explore the OpenAPI contract used for ingestion and search.
- [Functional Guide](reference/functional_guide.md) — end-user workflows and platform capabilities.
- [Backup & Restore](reference/BACKUP_RESTORE.md) — procedures for snapshots, restores, and retention.
- [Schema Reference](reference/SCHEMA_V2_REFERENCE.md) — canonical SQL definitions and views.

## Keeping Current
- [Contributing](contributing.md) — docs-as-code workflow, review checklist, and style guidance.
- [Changelog](changelog.md) — notable updates to the documentation set and supporting tooling.

Preview the site locally with:

```bash
pip install -r requirements-docs.txt
mkdocs serve
```

The navigation above maps directly to the MkDocs sidebar. Every page cites its source material so future updates can trace back to the primary documents.

_Adapted from `README.md`, `.tmp/docs/index.md`, and prior notes in `documentation/technical_reference.md`._
