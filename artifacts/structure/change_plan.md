# Change Plan Status

The structural fixes identified in the audit have been completed:

1. Gateway defaults now target `http://catalog:8081`, keeping proxy calls in sync with compose.
2. Collector compose profile renamed to `collector` with `CATALOG_ENDPOINT` wiring to the gateway proxy; unused `VECTOR_BACKEND` env removed.
3. Catalog and embedding worker share the `BAAI/bge-m3` + `haven_chunks` defaults for consistent embedding metadata.
4. Dependency guards swapped to match optional extras, and the broken `gateway-api` console script was removed from packaging.
5. Pruned cached bytecode directories to keep the repository tidy.

Outstanding follow-ups are limited to future enhancements (catalog duplication cleanup, infra linting, and test gaps) noted in `findings.md`.
