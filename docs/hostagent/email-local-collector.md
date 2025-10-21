# Email Local Collector

The Email Local collector orchestrates ingestion of macOS Mail.app `.emlx` messages through HostAgent. It provides HTTP endpoints that launch a collection run and expose the most recent state so other services (Gateway, CLI tools) can monitor progress.

## Overview

- **Module toggle:** controlled via `modules.mail.enabled` in `hostagent.yaml`.
- **Modes:** `simulate` (fixture-based) and `real` (scans live Mail.app cache; currently stubbed).
- **State tracking:** HostAgent records whether a run is in progress, the last result, timestamps, counters, and the last error string.
- **Permissions:** simulate mode does not require Full Disk Access; real mode will require Mail cache access once implemented.

## Run Endpoint — `POST /v1/collectors/email_local:run`

Launches a collection run. For now, only `simulate` mode is implemented.

### Request Body

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `mode` | `string` | Optional (default `simulate`) | Either `simulate` or `real`. |
| `limit` | `integer` | Optional (default `100`) | Maximum number of `.emlx` files to process (1–10,000). |
| `simulate_path` | `string` | Required for `simulate` | Absolute path to a single `.emlx` file or directory containing fixtures. |

Example (simulate mode):

```bash
curl -X POST http://localhost:7090/v1/collectors/email_local:run \
  -H "Content-Type: application/json" \
  -H "x-auth: change-me" \
  -d '{
        "mode": "simulate",
        "simulate_path": "/Users/alex/haven-fixtures/emlx",
        "limit": 50
      }'
```

### Success Response (`200 OK`)

```json
{
  "status": "completed",
  "mode": "simulate",
  "limit": 50,
  "simulate_path": "/Users/alex/haven-fixtures/emlx",
  "stats": {
    "messages_processed": 48,
    "documents_created": 48,
    "attachments_processed": 6,
    "errors_encountered": 0,
    "start_time": "2025-10-21T17:46:10.934Z",
    "end_time": "2025-10-21T17:46:11.121Z",
    "duration_ms": 187
  },
  "warnings": [
    "Failed to parse 1043.emlx: Email file not found: /Users/alex/haven-fixtures/emlx/1043.emlx"
  ]
}
```

#### Run Status Values

- `completed` — run finished without parse errors.
- `partial` — some messages failed to parse; warnings array is populated.
- `failed` — run aborted due to a fatal error (response includes `"error"` payload instead).

#### Validation & Error Responses

| HTTP Status | Reason |
|-------------|--------|
| `400 Bad Request` | Invalid mode, malformed JSON body, `limit` outside allowed range, or missing `simulate_path` in simulate mode. |
| `404 Not Found` | Provided `simulate_path` does not exist or contains no `.emlx` files. |
| `409 Conflict` | A run is already in progress. |
| `503 Service Unavailable` | Mail module disabled in config. |
| `501 Not Implemented` | Real mode invoked (placeholder). |

## State Endpoint — `GET /v1/collectors/email_local/state`

Returns the last known state without triggering a run.

Example:

```json
{
  "is_running": false,
  "status": "completed",
  "last_run_time": "2025-10-21T17:46:11.121Z",
  "last_run_stats": {
    "messages_processed": 48,
    "documents_created": 48,
    "attachments_processed": 6,
    "errors_encountered": 0,
    "start_time": "2025-10-21T17:46:10.934Z",
    "end_time": "2025-10-21T17:46:11.121Z",
    "duration_ms": 187
  },
  "last_run_error": null
}
```

### Fields

- `is_running` — boolean flag indicating an active run.
- `status` — last terminal status (`idle`, `running`, `completed`, `partial`, `failed`).
- `last_run_time` — ISO-8601 timestamp of the most recent run completion (if any).
- `last_run_stats` — same structure as the run response `stats` object; omitted if no prior runs.
- `last_run_error` — string containing the last fatal error, when applicable.

## Configuration

Enable the mail module and point to filters (advanced filtering is handled by HavenCore mail filters):

```yaml
modules:
  mail:
    enabled: true
    filters:
      combination_mode: any
      default_action: include
      files:
        - ~/.haven/email_collector_filters.yaml
```

Ensure the HostAgent process has permissions to read the directories referenced by `simulate_path`. For CI, commit `.emlx` fixtures into `hostagent/Tests/HostHTTPTests/Fixtures` and point the run request to the extracted fixture path on disk.

## Current Limitations

- `real` mode is stubbed until the Mail cache crawler (haven-54/30/31) is delivered.
- Attachments are counted but not yet enriched; enrichment happens inside the collector implementation.
- The handler focuses on orchestration and reporting; ingestion to Gateway is handled by the downstream collector tasks.
