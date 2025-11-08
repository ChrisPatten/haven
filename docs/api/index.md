# API Reference

Haven exposes the Gateway API as the public interface for ingestion and search. The interactive reference below is generated from the canonical OpenAPI specification committed to the repository.

| Service | Interactive Reference | Download Spec |
|---------|-----------------------|---------------|
| Gateway API | [Gateway documentation](gateway.md) | [Download YAML](../openapi/gateway.yaml) |

**Note:** Haven.app collectors run directly via Swift APIs and communicate with the Gateway API. There is no separate HTTP API for collectors.

To update the Gateway API reference, edit `openapi/gateway.yaml` in the repository and rebuild the documentation site. The MkDocs build pipeline validates the specification for OpenAPI v3 compatibility before publishing.
