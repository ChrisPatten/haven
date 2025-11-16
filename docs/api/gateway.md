# Gateway API

Gateway is the public entry point to Haven. It accepts ingestion payloads, brokers access to Catalog and Search, and keeps a thin orchestration layer around collectors. The OpenAPI specification is the canonical source of truth for all routes exposed on `:8085`.

<p>
  <a class="md-button md-button--primary" href="../../openapi/gateway.yaml" download>
    Download specification (YAML)
  </a>
  <a class="md-button" href="../gateway-reference.html?v=monokai" target="_blank" rel="noopener">
    Open interactive reference ↗
  </a>
</p>

## Using the Spec
- **Interactive viewer**: `docs/api/gateway-reference.html` is generated from `openapi/gateway.yaml` using `scripts/export_openapi.py`. Regenerate it whenever the spec changes:
  ```bash
  python scripts/export_openapi.py --input openapi/gateway.yaml --output docs/api/gateway-reference.html
  ```
- **MkDocs integration**: `scripts/docs_hooks.py` copies the spec into `docs/openapi/gateway.yaml` during builds so download links always point at the latest revision.
- **Validation**: CI validates the OpenAPI document as part of the docs publish workflow (see `.github/workflows/docs.yml`).

## Notable Endpoints
| Route | Purpose |
| --- | --- |
| `POST /v2/ingest/document` | Ingest a DocumentEnvelope (schema v2 payload) |
| `POST /v2/ingest/person` | Ingest a PersonEnvelope (contacts/identity) |
| `POST /v2/ingest:batch` | Submit an array of envelopes in a single request |
| `POST /v1/ingest` | Ingest text documents with people, thread context, and metadata |
| `POST /v1/ingest:batch` | Submit multiple documents in one request with batched forwarding to Catalog/Search |
| `POST /v1/ingest/file` | [Deprecated] Legacy binary upload route (superseded by `metadata.attachments`) |
| `GET /v1/ingest/{submission_id}` | Track ingestion status and chunk embedding progress |
| `GET /v1/search` | Perform hybrid lexical/vector search with facets and timeline filters |
| `GET /search/people` | Search for people by name, email, phone number, or organization |
| `POST /v1/ask` | Run curated search + summarisation with inline citations |
| `GET /v1/documents/{document_id}` | Retrieve persisted documents; `PATCH` to update text/metadata |

Authentication uses bearer tokens (`Authorization: Bearer <token>`). Downstream catalog/search calls rely on internal service tokens defined in your deployment environment.

`POST /v1/ingest:batch` automatically falls back to the single-document flow when the payload only contains one item, so existing collectors can opt-in to batch submission without losing backward compatibility. Each response echoes a `batch_id` that can be polled via `/v1/ingest/{submission_id}` for per-document progress.

## v2 Ingestion Envelopes
All cross-service ingestion uses an envelope wrapper. Gateway validates and forwards `payload` unchanged to Catalog v2 endpoints.

```json
{
  "schema_version": "2.0",
  "kind": "document",  // "document" | "person"
  "source": {
    "source_type": "imessage",
    "source_provider": "apple_messages",
    "source_account_id": "device:abc123"
  },
  "payload": { /* Document or Person object */ }
}
```

### DocumentEnvelope example
```json
{
  "schema_version": "2.0",
  "kind": "document",
  "source": { "source_type": "imessage", "source_provider": "apple_messages", "source_account_id": "device:abc123" },
  "payload": {
    "external_id": "imessage:GUID123",
    "version_number": 1,
    "title": "Dinner?",
    "text": "Hi, are we still on for dinner tonight at 7?",
    "text_sha256": "sha256:...",
    "mime_type": "text/plain",
    "canonical_uri": "imessage://chat/GUID123/message/456",
    "content_timestamp": "2025-01-01T17:30:00Z",
    "content_timestamp_type": "sent",
    "people": [
      { "identifier": "+15551234567", "identifier_type": "phone", "role": "sender", "display_name": "John Doe" }
    ],
    "thread": {
      "external_id": "imessage:chat144098762100126627",
      "thread_type": "group",
      "is_group": true
    },
    "relationships": { "thread_id": null, "parent_doc_id": null, "source_doc_ids": [], "related_doc_ids": [] },
    "facets": { "has_attachments": true, "attachment_count": 1, "has_location": false, "has_due_date": false, "due_date": null, "is_completed": null, "completed_at": null },
    "metadata": {
      "ingested_at": "2025-01-01T17:30:01Z",
      "timestamps": {
        "primary": { "value": "2025-01-01T17:30:00Z", "type": "sent" },
        "source_specific": { "sent_at": "2025-01-01T12:30:00-05:00" }
      },
      "attachments": [
        {
          "id": "sha256:abc123",
          "filename": "photo.jpg",
          "mime_type": "image/jpeg",
          "size_bytes": 123456,
          "role": "inline_image",
          "ocr": { "text": "Extracted text...", "confidence": 0.96, "language": "en" },
          "caption": "A group of people standing in front of a building",
          "vision": { "faces": [ { "x": 0.1, "y": 0.2, "w": 0.15, "h": 0.2, "confidence": 0.92 } ] }
        }
      ],
      "source": {},
      "type": { "kind": "imessage" },
      "enrichment": {},
      "extraction": {}
    }
  }
}
```

### PersonEnvelope example
```json
{
  "schema_version": "2.0",
  "kind": "person",
  "source": { "source_type": "contacts", "source_provider": "apple_contacts", "source_account_id": "device:abc123" },
  "payload": {
    "external_id": "apple_contacts:ABCDEF123456",
    "display_name": "Chris Patten",
    "given_name": "Chris",
    "family_name": "Patten",
    "organization": "Haven",
    "nicknames": ["Chris"],
    "version": 3,
    "deleted": false,
    "identifiers": [
      { "kind": "phone", "value_raw": "+1 (555) 123-4567", "value_canonical": "+15551234567", "label": "mobile", "priority": 10, "verified": true },
      { "kind": "email", "value_raw": "user@example.com", "value_canonical": "user@example.com", "label": "home", "priority": 100, "verified": true }
    ]
  }
}
```

### v1 vs v2
- v2 is envelope-based and transports normalized `Document`/`Person` payloads unchanged across services.
- v1 routes remain available for backward compatibility during migration. New clients should prefer v2.

### People Search

The `/search/people` endpoint provides full-text search across the normalized `people` table. This enables finding contacts by name, email, phone number, or organization:

```bash
curl -H "Authorization: Bearer $AUTH_TOKEN" \
  "http://localhost:8085/search/people?q=john&limit=20"
```

**Query Parameters**:
- `q`: Search query (matches display_name, given_name, family_name, organization, emails, phones)
- `limit`: Maximum results (default 20, max 200)
- `offset`: Pagination offset (default 0)

**Response**: Array of person records with identifiers and metadata.

**Use Cases**:
- Contact autocomplete in UI
- Finding people mentioned in conversations
- Verifying contact normalization worked correctly
- Building relationship intelligence features

_Adapted from `openapi/gateway.yaml`, `scripts/export_openapi.py`, and `documentation/technical_reference.md`._
