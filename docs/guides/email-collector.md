# Local Email Collector

This page is a short integration guide for the Local Email Collector mentioned by the hostagent email utilities.

Status: draft

## Purpose

The Local Email Collector reads `.emlx` files from Mail.app caches (or from a developer-provided copy) and streams parsed output to the Gateway for ingestion.

## Integration notes

- Ensure HostAgent's `mail` module is enabled in configuration.
- Collector runs on macOS and requires read access to Mail.app caches. For local development, set `HAVEN_IMESSAGE_CHAT_DB_PATH` (or equivalent) to point to a copy of the mailbox.
- The collector should use the Gateway `/v1/ingest/file` endpoint to send attachments and metadata.

## Security & Privacy

- Redact PII before sending to Gateway when running in production.
- Prefer a local developer copy of mail caches for testing to avoid exposing real user data.

## See also

- HostAgent Email Utilities (`../hostagent/email-utilities.md`)
- Bead: haven-25

<!-- placeholder: expand with sample config and commands -->
