# Haven Documentation

Haven is a personal data plane that keeps high-signal conversations, files, and local knowledge searchable without leaving your device. These pages collect the canonical runbooks, architecture notes, and API references.

## Start Here
- [Getting Started](getting-started.md) — install prerequisites, run the stack locally, and preview docs.
- [Haven.app Guide](guides/havenui.md) — unified macOS menu bar application for running collectors.
- [Repository Overview](guides/README.md) — tour of the source tree, collectors, and shared tooling.

## Architecture & Services
- [Architecture Overview](architecture/overview.md) — system context, data flow, and critical data stores.
- [Services](architecture/services.md) — responsibilities and interfaces for each core service.
- [Technical Reference](reference/technical_reference.md) — detailed schema, ingestion, and pipeline behaviour.

## Collectors
- [iMessage Collector](guides/collectors/imessage.md) — collect and index iMessage conversations.
- [Local Files Collector](guides/collectors/localfs.md) — watch directories and ingest files.
- [Contacts Collector](guides/collectors/contacts.md) — sync macOS Contacts and VCF files.
- [Email Collectors](guides/collectors/email.md) — IMAP and local Mail.app email collection.

## Configuration
- [Configuration Reference](reference/configuration.md) — complete guide to environment variables and settings.

## APIs
- [Gateway API](api/gateway.md) — download and explore the OpenAPI contract used for ingestion and search.
- [Functional Guide](reference/functional_guide.md) — end-user workflows and platform capabilities.

## Reference
- [Schema Reference](reference/SCHEMA_V2_REFERENCE.md) — canonical SQL definitions and views.
- [Backup & Restore](reference/BACKUP_RESTORE.md) — procedures for snapshots, restores, and retention.

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
