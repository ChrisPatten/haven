# Collector Run API

This document describes the unified Collector Run API for Haven Host Agent.

## Overview

The Collector Run API provides a standardized interface for running data collection operations across different collector types (iMessage, IMAP email, local email files). All collectors accept the same request format and return consistent response envelopes.

## Request Format

### CollectorRunRequest

The request body is a JSON object with the following fields:

| Field | Type | Description |
|-------|------|-------------|
| `mode` | string | Collection mode: `"simulate"` or `"real"` |
| `limit` | integer | Maximum number of items to process |
| `order` | string | Sort order: `"asc"` or `"desc"` |
| `concurrency` | integer | **Number of concurrent operations (1-12)** |
| `date_range` | object | Date range filter with `since` and `until` ISO8601 timestamps |
| `time_window` | integer | Time window in days (alternative to `date_range`) |
| `collector_options` | object | Collector-specific options (optional) |

### Concurrency Parameter

The `concurrency` parameter controls the number of concurrent operations during collection:

- **Valid range**: 1-12
- **Default**: Not set (collector uses its default)
- **Clamping**: Values outside the 1-12 range are automatically clamped to the nearest boundary
- **Logging**: When clamping occurs, a warning is logged with the original and clamped values

#### Examples

```json
{
  "concurrency": 6,
  "mode": "real",
  "limit": 1000
}
```

If `concurrency` is set to `0`, `-5`, `20`, or `100`, it will be clamped to `1`, `1`, `12`, or `12` respectively, with appropriate warning messages logged.

## Response Format

### RunResponse

All collectors return a standardized response envelope:

```json
{
  "collector": "imessage",
  "run_id": "uuid-string",
  "started_at": "2025-10-27T15:00:00Z",
  "finished_at": "2025-10-27T15:05:00Z",
  "status": "ok",
  "stats": {
    "scanned": 1500,
    "matched": 1200,
    "submitted": 1180,
    "skipped": 20,
    "batches": 12
  },
  "warnings": ["concurrency value 15 out of range, clamped to 12"],
  "errors": []
}
```

## Collector-Specific Endpoints

- `POST /v1/collectors/imessage:run` - Run iMessage collection
- `POST /v1/collectors/imap:run` - Run IMAP email collection
- `POST /v1/collectors/local_mail:run` - Run local email file collection

## Error Handling

- **400 Bad Request**: Invalid JSON or unknown fields
- **404 Not Found**: Unknown collector type
- **500 Internal Server Error**: Collection processing errors

## Validation

- Unknown JSON fields cause request rejection
- Invalid enum values are rejected
- Date formats must be ISO8601
- Concurrency values are clamped with warnings rather than rejection