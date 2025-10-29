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
| `POST /v1/ingest` | Ingest text documents with people, thread context, and metadata |
| `POST /v1/ingest:batch` | Submit multiple documents in one request with batched forwarding to Catalog/Search |
| `POST /v1/ingest/file` | Upload binaries (images, PDFs, etc.) with enrichment metadata |
| `GET /v1/ingest/{submission_id}` | Track ingestion status and chunk embedding progress |
| `GET /v1/search` | Perform hybrid lexical/vector search with facets and timeline filters |
| `POST /v1/ask` | Run curated search + summarisation with inline citations |
| `GET /v1/documents/{document_id}` | Retrieve persisted documents; `PATCH` to update text/metadata |

Authentication uses bearer tokens (`Authorization: Bearer <token>`). Downstream catalog/search calls rely on internal service tokens defined in your deployment environment.

`POST /v1/ingest:batch` automatically falls back to the single-document flow when the payload only contains one item, so existing collectors can opt-in to batch submission without losing backward compatibility. Each response echoes a `batch_id` that can be polled via `/v1/ingest/{submission_id}` for per-document progress.

_Adapted from `openapi/gateway.yaml`, `scripts/export_openapi.py`, and `documentation/technical_reference.md`._
