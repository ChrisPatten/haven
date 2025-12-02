# Conversational Search Service Design

This document designs the end-to-end flow from a user question in the Custom GPT UI, through the Gateway and Search services, back to a final response enriched with facets and supporting metadata.

## Goals

1. **Natural-language querying with facets** – let the user ask “What did Mia send last week about travel?” and receive a conversational answer plus the ability to inspect or edit filters (date, person, source, tags, attachments, etc.).
2. **Transparent, citeable answers** – every response should cite at least one document/chunk with metadata (document id, thread, people, scores) so the assistant can surface trust signals.
3. **LLM-first translation** – rely on LLM steps (no brittle hard-coded parsers) to turn the question into facet filters, search queries, and final narratives while leveraging the rich metadata ingested with every document.
4. **Faceted refinement** – provide a `/v1/search/facets` capability so the assistant can surface clickable chips/chunks with counts and keep the conversation state in sync.

## High-Level Architecture

1. **Custom GPT UI** posts to `POST /v1/search/converse` with `{question, conversation_id?, facet_filters?, top_k?}`.
2. **Gateway** forwards this request to the Search service and returns the structured response (answer, documents, facets, inferred filters) plus any metadata required by the UI chips.
3. **Search service** orchestrates the translation, retrieval, and answer synthesis steps before returning to the gateway.

## End-to-End Flow

### 1. Question Intake & Context

- Custom GPT sends the user’s question along with the current `conversation_id`, retained facet overrides, and optionally a `conversation_metadata` blob (chains of prior questions/answers).
- Gateway validates auth and forwards the request to `/v1/search/converse`.
- Search service persists/extends `conversation_id` to maintain faceted context across turns.

### 2. LLM-driven Translation Step (Search Planner)

This is the first dedicated LLM inference:

- **Inputs:** natural language question, prior inferred filters, `conversation_metadata`, schema describing available metadata facets (people, source_type, attachments, tags, thread, importance, timeline).
- **Outputs (Search Plan):**
  * Top-k retrieval target (a textual query or prompt for the ranking model).
  * Structured `facet_filters` (terms, ranges, boolean flags) inferred from the question (e.g., “last week” → `date` range, “Mia” → `person=Mia`). The schema uses metadata names ingested from collectors (timestamps, source_type, people identifiers, tags, `has_attachments`, `thread_id`, `document_level.is_flagged`, etc.).
  * Retrieval strategy hint (lexical vs. vector emphasis, context window, whether attachments should be prioritized).
  * Summarization intent (answer style: `summary`, `list`, `comparison`), which guides downstream LLM.

- We explicitly rely on an LLM for this translation (e.g., prompt the model with examples and metadata schema). That same LLM can optionally return provenance instructions (which metadata fields to highlight) so answers stay traceable.
- We use `haven_llm` to perform this translation.

### 3. Search Execution

- The translator’s `facet_filters` + textual query feed into the hybrid search pipeline (existing Postgres + Qdrant search). The search service:
  * Applies filters to metadata-rich columns (people identifiers, `source_type`, timeline ranges, `has_attachments`, `thread_id`, `tags`, custom metadata like `importance` or `topic`).
  * Pulls candidate chunks (`top_k`, `context_window`) and enriches them with metadata (attachments list, thread summary, people roles, entity mentions).
  * Uses shared context utilities (e.g., `context` Python module) to expand each hit’s neighborhood. For iMessage hits we grab surrounding messages from -8 hours to +1 hour, obeying a per-hit message cap (`N` upper limit) so the Custom GPT can reason over a contiguous conversation slice without overfetching.
  * Calculates facet bucket counts for each metadata axis so that the response can show how many hits exist per facet value, as well as the ones that the translator already marked as selected.

- If embeddings are missing, the backend includes a warning in the `metadata` field of the response so the assistant can surface degradation.

### 4. Answer Synthesis (Custom GPT)

- The search service now focuses on delivering rich retrieval payloads (hits, metadata, facets, inferred filters, counts), while the Custom GPT is responsible for synthesis.
- Custom GPT receives:
  * The original question and translator narrative.
  * Retrieved chunks (`SearchHit`) with metadata/attachments/relevance scores.
  * Selected facets and counts for traceability.
- It uses those inputs to build the conversational response: summarizing key documents, citing each assertion (`document_id`, `chunk_id`, `score`), suggesting next facets, surfacing confidence, and explaining applied filters.
- Search service returns this data via `SearchConverseResponse` so the GPT can compose the final narrative without the backend doing the synthesis.

### 5. Facet Suggestions Endpoint

- When the Custom GPT wants to show available facet chips or confirm counts before applying filters, it calls `POST /v1/search/facets` with the latest question/conversation state.
- Search service (or same translator LLM) recalculates buckets for metadata axes, sorts them by relevance/count, and returns `facets` with `FacetValue.count` and `selected` flags.
- These facets drive the UI chips/buttons. Selecting a chip updates the `facet_filters` array (JSON + conversation_id) and re-invokes `/v1/search/converse`.
- This separation keeps facet discovery fast, while the `/converse` endpoint focuses on answer generation.

## Metadata Utilization

Every step leverages ingest-time metadata:

| Metadata Axis | Source | Usage |
| --- | --- | --- |
| `people` | Collector payloads (iMessage/Email/Contacts) | `person` facet, citations, summary context (who spoke). |
| `source_type` | Ingest info (imessage, email, files, reminders, contacts) | Term facet; translator can bias summarization (“iMessage vs email answer”). |
| `thread_id` / `thread.summary` | Catalog thread tracking | Helps synthesize conversations, timeline splits, dedupe repeated info. |
| `content_timestamp` / `created_at` | Document/Chunk timestamps | Range facet, answer includes “between X and Y”. |
| `has_attachments` & `attachment_types` | File ingestion metadata | Allows filtering “only results with receipts”, and translations can highlight attachments being cited. |
| `tags`, `importance`, `status` | Custom metadata from collectors | Provide derived facets and contextual cues for translators/answer LLM. |
| `entities`, `topics`, `summary` fields | Enrichment outputs (OCR, entity extraction) | Feed translation (“focus on travel” → `topic=travel`), supply answer details. |

Facets must include counts and selected flags so the UI knows what’s active, and the translator’s inferred filters are returned to help the assistant explain “Assuming you meant emails from Mia after 2025-03-20”.

## Conversation Management

- `conversation_id` persists in responses so the UI retains context for follow-ups.
- The search service stores (or caches) the latest translator output per conversation to accelerate inference (e.g., embeddings+translation for repeated “show receipts”).
- Follow-up questions reuse prior metadata: the next question can be “narrow to just PDF receipts” while keeping the prior inferred filters, enabling chaining without re-specifying everything.

## Observability & Privacy

- Log translator input/output so we can tune prompts and inspect facet translation accuracy.
- Track per-request metadata (which facets were hit, top documents) for debugging.
- Respect collector-level privacy constraints: faceted metadata may be omitted if the document was marked private; the translator and answer LLM should fail gracefully with “missing data” warnings in metadata.

## Next Steps

1. Implement translation/summary LLM pipelines inside `services/search_service` (or via an LLM orchestrator) and hook them into the new `/v1/search/converse` and `/v1/search/facets` endpoints.
2. Extend the Gateway and Custom GPT OpenAPI specs so the UI can pass/from facet chips and surface citations.
3. Add tests or canned flows that verify facet inference (e.g., “emails mentioning travel” maps to `topic=travel`) and answer generation references real citations.
