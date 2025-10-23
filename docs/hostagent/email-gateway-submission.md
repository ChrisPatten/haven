# Email Gateway Submission

This page documents how the HostAgent email collector constructs ingestion payloads and submits them to the Gateway APIs. The Swift implementation lives under `hostagent/Sources/HostAgent/Collectors/EmailCollector.swift` with HTTP submission handled by `Submission/GatewaySubmissionClient.swift`.

## Overview

- **Endpoint targets**
  - `POST /v1/ingest` for redacted email document payloads.
  - `POST /v1/ingest/file` for binary attachments plus enrichment metadata.
- **Idempotency keys**
  - Documents: `SHA256("{source_type}:{source_id}:{text_hash}")`, where `text_hash` is the SHA-256 of the normalized body (CRLF → LF, trimmed) before redaction.
  - Attachments: `email-attachment:{message_id_or_hash}:{file_sha256}`.
- **Retries**
  - Automatically retries transient Gateway responses (`429`, `503`) using exponential back-off (0.5s, 1.0s).
  - Treats other `4xx` responses as hard failures and surfaces the body text in logs.

## Document Payload Shape

```json
{
  "source_type": "email_local",
  "source_id": "email:message-123",
  "title": "Receipt for your order",
  "content": {
    "mime_type": "text/plain",
    "data": "Hello [EMAIL_REDACTED], thanks for your payment...",
    "encoding": null
  },
  "people": [
    {
      "identifier": "billing@example.com",
      "identifier_type": "email",
      "role": "sender",
      "display_name": "Billing"
    },
    {
      "identifier": "alice@example.com",
      "identifier_type": "email",
      "role": "recipient"
    }
  ],
  "metadata": {
    "message_id": "message-123",
    "subject": "Receipt for your order",
    "snippet": "Hello [EMAIL_REDACTED], thanks for your payment...",
    "content_hash": "ce62…",
    "in_reply_to": "parent-456",
    "references": ["parent-456","root-001"],
    "has_attachments": true,
    "attachment_count": 2,
    "intent": {
      "primary_intent": "receipt",
      "confidence": 0.92,
      "secondary_intents": ["actionRequired"],
      "extracted_entities": {
        "amount": "42.00",
        "currency": "USD"
      }
    },
    "relevance_score": 0.87
  },
  "thread_id": "eb3f5f8c-…",
  "thread": {
    "external_id": "email-thread:85e43…",
    "source_type": "email",
    "title": "Receipt for your order",
    "participants": [
      { "identifier": "billing@example.com", "role": "sender" },
      { "identifier": "alice@example.com", "role": "recipient" }
    ],
    "metadata": {
      "message_ids": "message-123,parent-456,root-001"
    }
  },
  "relevance_score": 0.87
}
```

### Field Notes

- **Redaction** – Bodies are run through `EmailService.redactPII` (emails, phone numbers, account numbers, SSNs) before hashing.
- **People** – Sender, To, Cc, and Bcc addresses are deduplicated and lowercased.
- **Thread** – Deterministic UUID derived from all message IDs (current, parent, references). Absent if no threading headers exist.
- **Intent** – Optional; populated from `IntentClassification` when available and mirrored on both `metadata.intent` and top-level `intent`.
- **Timestamps** – `content_timestamp` is set from the email `Date` header with `content_timestamp_type="received"` by default.

## Attachment Uploads

Attachments are uploaded individually using multipart form data. The collector computes the SHA-256 hash **before** submitting to minimise duplicate uploads.

Metadata envelope:

```json
{
  "source": "email_local",
  "path": "email/message-123/invoice.pdf",
  "filename": "invoice.pdf",
  "mime_type": "application/pdf",
  "sha256": "94fe…",
  "size": 20480,
  "message_id": "message-123",
  "content_id": "cid-abc123",
  "intent": {
    "primary_intent": "receipt",
    "confidence": 0.92
  },
  "relevance_score": 0.87,
  "enrichment": {
    "ocr_text": "Total due $42.00",
    "entities": { "amount": ["42.00"], "merchant": ["Acme"] },
    "caption": "Scanned receipt with store logo"
  }
}
```

- The metadata JSON is passed in the `meta` field; binary bytes are provided in `upload`.
- The same intent and relevance score from the parent document can be mirrored at the attachment level.
- When enrichment fails, the collector still submits the file but omits the `enrichment` object.

## Configuration

Add (or confirm) the Gateway configuration block in `~/.haven/hostagent.yaml`:

```yaml
gateway:
  base_url: http://gateway:8085
  ingest_path: /v1/ingest
  ingest_file_path: /v1/ingest/file
  timeout: 30
```

The `ingest_file_path` property defaults to `/v1/ingest/file` for backwards compatibility, so older configuration files continue to work without edits.

### Email collector state configuration

```yaml
modules:
  mail:
    enabled: true
    state:
      clear_on_new_run: true               # discard prior per-run map when new items are discovered
      run_state_path: ~/.haven/email_collector_state_run.json
      rejected_log_path: ~/.haven/rejected_emails.log
      lock_file_path: ~/.haven/email_collector.lock
      rejected_retention_days: 30          # daily rotated logs kept for this many days
```

All fields are optional; the defaults shown match the built-in configuration. When `clear_on_new_run` is `true`, discovering any new Envelope Index rows clears the previous per-run map before processing; set it to `false` to reattempt outstanding submissions across runs. The lock file prevents two collectors from processing the same mailbox concurrently.

## Error Handling & Logging

- All Gateway interactions log structured events under the `gateway-submission` category.
- On non-retryable failures (`4xx` other than `429`), the error body is logged and propagated to the caller.
- After three retry attempts, the client raises `EmailCollectorError.gatewayHTTPError(-1, "Exceeded retry attempts")`.
- Attachment read failures bubble up as `EmailCollectorError.attachmentReadFailed`; the collector may choose to skip the offending file but continue with the remaining batch.
- The email collector persists a per-run submission map to `run_state_path` (default `~/.haven/email_collector_state_run.json`). Each entry records the Gateway idempotency key, attempts, last attempt timestamp, and the latest status (`found`, `submitted`, `accepted`, `rejected`).
- Final rejections are appended as newline-delimited JSON to `rejected_emails-YYYY-MM-DD.log` (rotated daily), including the row ID, idempotency key, and server response to aid triage.

### Admin endpoints

`GET /v1/collectors/email_local/state` now includes the run-state snapshot:

```json
{
  "status": "completed",
  "run_state": {
    "last_accepted_rowid": 42,
    "entries": [
      {
        "key": "42",
        "row_id": 42,
        "external_id": "email:message-123",
        "status": "accepted",
        "attempts": 1,
        "last_attempt_at": "2025-10-22T23:45:01.238Z",
        "mailbox": "Inbox"
      },
      {
        "key": "43",
        "row_id": 43,
        "status": "submitted",
        "attempts": 2,
        "last_error": "Gateway HTTP error 503: Service Unavailable"
      }
    ]
  }
}
```

This payload omits message bodies and attachment data, exposing only metadata needed for operational debugging.

### Metrics

The collector emits Prometheus-style metrics through `/v1/metrics`:

- `email_local_found_total{mailbox="Inbox"}` – messages discovered in the current run.
- `email_local_submitted_total{mailbox="Inbox"}` – submission attempts (documents).
- `email_local_accepted_total{mailbox="Inbox", duplicate="false"}` – documents accepted or deduplicated by Gateway.
- `email_local_rejected_total{mailbox="Inbox", status="400"}` – hard failures that will not be retried.
- `email_local_submission_latency_ms{mailbox="Inbox"}` – histogram of end-to-end submission latency in milliseconds.

## Testing

Unit tests in `hostagent/Tests/SubmissionTests/EmailCollectorTests.swift` verify:

- Payload redaction, people extraction, and hash stability.
- Document requests include the computed idempotency key header.
- Attachment uploads retry automatically on `429` and propagate enrichment metadata.

These tests use a custom `URLProtocol` to simulate Gateway responses, ensuring developers can iterate locally without reaching the real API.
