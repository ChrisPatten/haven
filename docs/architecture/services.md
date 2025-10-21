# Services

This section will outline each Haven service and its responsibilities.

## Gateway

- Public API surface for ingestion and orchestration.

## Catalog

- Source of truth for documents, versions, and metadata.

## Search

- Hybrid lexical/vector search built on Qdrant.

## HostAgent

- macOS-native agent providing OCR, file watching, and collectors.

## Embedding Worker

- Processes text chunks and pushes vectors into Qdrant.

> Additional services (e.g., future collectors) will be documented as the system evolves.
