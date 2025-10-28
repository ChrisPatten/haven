# Email IMAP Collector

The IMAP collector allows HostAgent to fetch remote mailbox content over IMAP and push it through the existing email processing pipeline. This is useful for staging or backfill runs where Mail.app does not have a local cache of the account.

## Status and Scope
- **Auth**: XOAUTH2 and app-specific passwords (basic SASL) via Keychain references or one-off inline secrets.
- **Storage**: Messages are kept in-memory only. Attachments and on-disk caches will be handled by the upcoming EphemeralCache work.
- **Gateway Integration**: Payloads are identical to the local collector, so deduplication and idempotency behave the same way.

> **Rosetta requirement**
> The current MailCore 2 binary ships as an x86_64-only framework. Build and run HostAgent under Rosetta for now:
> ```bash
> arch -x86_64 swift build
> arch -x86_64 swift run hostagent --config ~/.haven/hostagent.yaml
> ```
> A universal (`arm64`) MailCore build is on the backlog.

## Configuration
Enable the module and describe remote accounts in `~/.haven/hostagent.yaml`:

```yaml
modules:
  mail:
    enabled: true
    # Module-level redaction default (applies to all sources unless overridden)
    redact_pii: true  # or false, or detailed object
    
    sources:
      - id: personal-icloud
        type: imap
        enabled: true
        host: imap.mail.me.com
        port: 993
        tls: true
        username: user@example.com
        auth:
          kind: app_password
          secret_ref: keychain://haven/icloud-mail
        folders:
          - INBOX
          - "Receipts"
        redact_pii:  # Fine-grained override
          emails: false
          phones: true
          account_numbers: true
          ssn: true
```

Secrets are resolved through the Keychain resolver using the `keychain://service/account` format. Create entries with the Keychain Access app or the `security` CLI (generic password items).

## PII Redaction Configuration

The IMAP collector supports configurable PII redaction at both module and source levels:

**Module-level redaction** (applies to all sources unless overridden):
```yaml
modules:
  mail:
    redact_pii: true  # Enable all redaction types
    # or
    redact_pii: false  # Disable all redaction
    # or
    redact_pii:
      emails: true
      phones: false
      account_numbers: true
      ssn: true
```

**Source-level redaction** (overrides module defaults):
```yaml
sources:
  - id: work-email
    type: imap
    redact_pii: false  # Disable redaction for this source
  - id: personal-email
    type: imap
    redact_pii:  # Fine-grained control
      emails: false
      phones: true
      account_numbers: true
      ssn: true
```

**Resolution order**: source override → module default → true (all enabled)

## Running the Collector
Call the API endpoint to start a run:

```bash
curl -s -X POST \
  -H "x-auth: $HOSTAGENT_TOKEN" \
  -H "Content-Type: application/json" \
  http://localhost:7090/v1/collectors/email_imap:run \
  -d @- <<'JSON'
{
  "account_id": "personal-icloud",
  "folder": "INBOX",
  "limit": 25,
  "since": "2024-09-01T00:00:00Z",
  "dry_run": false,
  "credentials": {
    "kind": "app_password",
    "secret_ref": "keychain://haven/icloud-mail"
  }
}
JSON
```

### Inline secrets for ad-hoc testing
You can supply a one-off secret in the request body instead of a Keychain reference:

```json
{
  "account_id": "personal-icloud",
  "folder": "Receipts",
  "limit": 10,
  "dry_run": true,
  "credentials": {
    "kind": "app_password",
    "secret": "APP_SPECIFIC_PASSWORD"
  }
}
```

Inline secrets are only kept in-memory for the duration of the request and never persisted.

## Response Payload
The handler returns run statistics and per-message outcomes:

```json
{
  "accountId": "personal-icloud",
  "folder": "INBOX",
  "totalFound": 42,
  "processed": 25,
  "submitted": 24,
  "dryRun": false,
  "results": [
    {
      "uid": 12345,
      "messageId": "<abc@example.com>",
      "status": "accepted",
      "submissionId": "sub_01HF...",
      "docId": "doc_01HF...",
      "duplicate": false
    }
  ],
  "errors": [
    {
      "uid": 12340,
      "reason": "NSURLErrorDomain -1001 (timed out)"
    }
  ]
}
```

- `totalFound`: Number of UIDs returned by the IMAP search.
- `processed`: Messages fetched during this run (limited by `limit`).
- `submitted`: Successful Gateway submissions (duplicates count as submitted).
- `results`: Per-UID status, including Gateway submission identifiers.
- `errors`: UID + message for any final failures.

## Known Gaps
- Attachments are not downloaded yet (blocked on `haven-67`).
- The collector currently runs in-memory only; restart to clear state.
- Search predicates are limited to `since/before` date bounds. Folder-level filtering happens server-side.
- The MailCore framework bundled with HostAgent only supports x86_64 builds.

## Troubleshooting
| Symptom | Fix |
| --- | --- |
| `IMAP search failed (MCOErrorDomain#1)` | Check host/port/TLS flags and confirm connectivity. |
| `IMAP fetch failed (NSURLErrorDomain#-1001)` | Increase timeout or re-run; the collector retries transient errors automatically. |
| `400 Bad Request` | Ensure `mail_imap.enabled` is `true` and the account `id` exists in the config. |
| Gateway rejects submissions | Inspect the `errors` array; duplicates return status `duplicate=true` in `results`. |

## See Also
- [Email Local Collector](email-local-collector.md)
- [Email Gateway Submission](email-gateway-submission.md)
