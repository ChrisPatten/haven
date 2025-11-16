## 1. Purpose and scope

This document defines a standardized, service-agnostic communication model for Haven built around two object types:

* `Document` – everything that is “content” (messages, files, notes, reminders, events, etc.).
* `Person` – canonical people/contact information and identifiers.

Haven.app (collectors, enrichment), Gateway, and Catalog will all communicate exclusively using these two objects over HTTP boundaries. Contacts flow through the `Person` object; everything else flows through `Document`, even when the underlying database representation is a `contact` document or a row in the `people` tables. The model is aligned with the existing unified schema and data dictionary.

Takeaway: one envelope format, two object types (`document`, `person`), used consistently between all components.

---

## 2. Design principles

1. **Single source of truth per concern**

   * `Document` maps to the `documents` table and its JSONB metadata, people, threads, and chunks.
   * `Person` maps to the `people` + `person_identifiers` + `people_source_map` tables, as well as contact ingestion payloads.

2. **Transport-level neutrality**

   * The same JSON structures are used:

     * Haven.app → Gateway
     * Gateway → Catalog
     * Future external clients → Gateway

3. **Progressive enhancement**

   * Payloads must be valid with only core identity and content.
   * Additional enrichment (OCR, faces, entities, intent) is layered into fixed metadata partitions (`metadata.enrichment`, `metadata.attachments`, etc.).

4. **Idempotency and versioning aware**

   * Idempotency keys and versioning map directly to `ingest_submissions` and `documents.version_number`.

5. **Strictly-typed “people” model**

   * All per-document participants use the existing `Person Payload` structure (identifier, identifier_type, role, display_name, metadata).
   * Contacts/roster-level data uses `Person` objects that are normalized into `people` and `person_identifiers`.

Takeaway: schemas are thin wrappers over what already exists in Postgres and the data dictionary, not a new model.

---

## 3. High-level flow

### 3.1 Document flow

1. **Collector → Haven.app internal**

   * Source-specific inputs (chat.db rows, filesystem entries, email messages, reminders) are mapped into an internal `AppDocument` that mirrors `Document` fields (see §5). This wraps `CollectorDocument` + `EnrichedDocument` concepts into one structure.

2. **Haven.app → Gateway**

   * App sends `DocumentEnvelope` JSON over HTTP (e.g. `POST /v2/ingest/document`).
   * Attachments (images, files) are represented inside `document.metadata.attachments`, not as separate payloads.

3. **Gateway → Catalog**

   * Gateway validates, normalizes timestamps, computes idempotency key, and forwards the same `Document` structure to Catalog’s `/v2/catalog/documents`.

4. **Catalog → Gateway (response)**

   * Catalog returns a `DocumentIngestResponse` which is unchanged conceptually but versioned as v2: `submission_id`, `doc_id`, `external_id`, `version_number`, `thread_id`, `status`, `duplicate`, plus optional `ingestion_warnings`.

### 3.2 Person flow

1. **Haven.app (contacts, identity sources) → Gateway**

   * Collectors emit `PersonEnvelope` for each contact or person-like entity (e.g., Apple Contacts, email address book, phone contacts).
   * Contacts no longer flow as `contact` documents; they flow as `Person` objects (even if Catalog stores a contact document as well).

2. **Gateway → Catalog**

   * Gateway posts `Person` payloads to `/v2/catalog/people` which normalizes into `people`, `person_identifiers`, and maintains `people_source_map`.

3. **Documents referencing people**

   * `Document.people` contains lightweight `PersonRef` objects (Person Payload) with identifiers and roles but no full contact card.
   * Resolution to canonical people happens at query time using `person_identifiers`.

Takeaway: `Document` is “what happened”, `Person` is “who they are.”

---

## 4. Envelope format

All cross-service messages use a simple envelope wrapper:

```json
{
  "schema_version": "2.0",
  "kind": "document",  // "document" | "person"
  "source": {
    "source_type": "imessage",
    "source_provider": "apple_messages",
    "source_account_id": "device:abc123"
  },
  "payload": { /* Document or Person object, see below */ }
}
```

Rules:

* `schema_version` is a semantic version for the envelope + payload schema, independent of service versions.
* `kind` selects which payload schema applies.
* `source.*` mirrors the existing `source_type`, `source_provider`, `source_account_id` used in `documents` and `threads`.
* Additional envelope-level fields may be added later (`batch_id`, trace IDs) but must be optional.

Takeaway: one envelope to rule all encodings; `payload` is the only variant.

---

## 5. Document object

### 5.1 Core schema

The `Document` payload is the transport representation of a `documents` row plus its structured metadata.

```json
{
  "external_id": "imessage:GUID123",
  "version_number": 1,
  "title": "Example message snippet",
  "text": "Hi, are we still on for dinner tonight at 7?",
  "text_sha256": "<sha256-of-text>",
  "mime_type": "text/plain",
  "canonical_uri": "imessage://chat/GUID123/message/456",

  "content_timestamp": "2025-01-01T17:30:00Z",
  "content_timestamp_type": "sent",
  "content_created_at": "2025-01-01T17:29:59Z",
  "content_modified_at": null,

  "people": [ /* PersonRef[] – see §5.2 */ ],
  "thread": { /* ThreadHint – see §5.3 */ },

  "relationships": {
    "thread_id": null,
    "parent_doc_id": null,
    "source_doc_ids": [],
    "related_doc_ids": []
  },

  "facets": {
    "has_attachments": true,
    "attachment_count": 1,
    "has_location": false,
    "has_due_date": false,
    "due_date": null,
    "is_completed": null,
    "completed_at": null
  },

  "metadata": { /* DocumentMetadata – see §5.4 */ },

  "intent": { /* Optional simplified intent – see §5.5 */ }
}
```

Mapping to Postgres:

* All fields under the “Core schema” map directly to `documents` top-level columns, except:

  * `relationships.*` → `thread_id`, `parent_doc_id`, `source_doc_ids`, `related_doc_ids`
  * `facets.*` → `has_attachments`, `attachment_count`, `has_location`, `has_due_date`, `due_date`, `is_completed`, `completed_at`
  * `metadata` → `documents.metadata` JSONB
  * `intent` → `documents.intent` JSONB

Takeaway: `Document` is a 1:1 correspondence with `documents` plus some normalized sub-structures.

### 5.2 People (per-document participants)

`people` is an array of `PersonRef`, reusing the Person Payload definition:

```json
"people": [
  {
    "identifier": "+15551234567",
    "identifier_type": "phone",      // phone | email | imessage | shortcode | social
    "role": "sender",                // sender | recipient | participant | mentioned | contact
    "display_name": "John Doe",
    "metadata": {
      "device_label": "iPhone 15"
    }
  }
]
```

Mapping:

* Stored as-is in `documents.people` JSONB field.

Rules:

* `people` must always be present (possibly empty).
* Collectors must at least identify the local user (`role="sender"` or `"participant"`) when possible.
* Contact details beyond identifier + display_name belong in `Person` objects, not here.

### 5.3 Thread hint

Thread identity and lifecycle are owned by Catalog, but collectors provide hints. The `thread` block mirrors the conceptual thread schema and behavior.

```json
"thread": {
  "external_id": "imessage:chat144098762100126627",
  "thread_type": "group",
  "is_group": true,
  "title": "Family Chat",
  "participants": [
    { "identifier": "+15551234567", "identifier_type": "phone", "role": "participant" }
  ],
  "metadata": {
    "imessage": { "chat_guid": "chat144098762100126627" }
  }
}
```

Behavior:

* Catalog upserts `threads` using `(source_type, source_provider, source_account_id, external_id)`.
* `participants` is normalized to the same structure as `documents.people`.
* `first_message_at` / `last_message_at` are maintained from `content_timestamp` (min/max).

### 5.4 Metadata partitions

`metadata` follows the standardized top-level keys:

```json
"metadata": {
  "ingested_at": "2025-01-01T17:30:01Z",
  "timestamps": {
    "primary": {
      "value": "2025-01-01T17:30:00Z",
      "type": "sent"
    },
    "source_specific": {
      "sent_at": "2025-01-01T12:30:00-05:00",
      "fs_created": "2025-01-01T12:29:59-05:00"
    }
  },
  "attachments": [ /* see below */ ],
  "source": { /* raw source-system details */ },
  "type": { /* normalized semantics per kind */ },
  "enrichment": { /* ML-derived structures */ },
  "extraction": { /* ingestion/parsing diagnostics */ }
}
```

Key rules:

* `metadata.ingested_at` (if present) must equal `documents.ingested_at` in UTC.
* `metadata.timestamps.primary.value` must equal `content_timestamp`; `type` must equal `content_timestamp_type`.
* `metadata.attachments` is the sole owner of OCR, captions, faces, EXIF, and file-level enrichment.

#### 5.4.1 Attachments

Attachment schema as defined in the data dictionary is reused; the structure must include:

* File-level properties (filename, size, mime_type, sha256).
* Enrichment: `ocr`, `caption`, `vision`, `exif`.

Example (abbreviated):

```json
"attachments": [
  {
    "id": "sha256:abc123",
    "filename": "photo.jpg",
    "mime_type": "image/jpeg",
    "size_bytes": 123456,
    "role": "inline_image",
    "ocr": { /* as per File Enrichment section */ },
    "caption": "A group of people standing in front of a building",
    "vision": {
      "faces": [ { "x": 0.1, "y": 0.2, "w": 0.15, "h": 0.2, "confidence": 0.92 } ]
    },
    "exif": { /* EXIF metadata */ }
  }
]
```

This aligns with the enrichment and OCR examples in the data dictionary.

### 5.5 Intent (optional)

The simplified intent field is carried as-is from the data dictionary:

```json
"intent": {
  "primary_intent": "bill",
  "confidence": 0.85,
  "secondary_intents": ["receipt"],
  "extracted_entities": {
    "amount": "$123.45",
    "merchant": "Example Store"
  }
}
```

Rules:

* Optional for all services; can be omitted or partially filled.
* When present, Catalog writes directly to `documents.intent`.

Takeaway: `Document` payload is strictly a normalized view of the unified schema v2, but with better structuring of metadata and people.

---

## 6. Person object

The `Person` object standardizes all contact and identity data flows.

### 6.1 Core schema

```json
{
  "external_id": "apple_contacts:ABCDEF123456",
  "display_name": "Chris Patten",
  "given_name": "Chris",
  "family_name": "Patten",
  "organization": "Haven",
  "nicknames": ["Chris"],
  "notes": "Friend from college",
  "photo_hash": "sha256:...",
  "change_token": "C:12345",
  "version": 3,
  "deleted": false,

  "identifiers": [ /* Identifier[] – see §6.2 */ ]
}
```

This merges the Contact Payload (contacts ingestion) with the canonical people table schema:

Rules:

* `external_id` tracks the source contact ID for use in `people_source_map`.
* `version` and `change_token` support incremental sync and conflict resolution.
* `deleted` indicates contact deletion at the source; Catalog should mark the corresponding `people.deleted` flag and/or handle removal of associated contact documents.

### 6.2 Identifiers

Identifiers unify the `ContactValue` model and `person_identifiers`:

```json
"identifiers": [
  {
    "kind": "phone",             // phone | email | imessage | shortcode | social
    "value_raw": "+1 (555) 123-4567",
    "value_canonical": "+15551234567",
    "label": "mobile",
    "priority": 10,
    "verified": true
  },
  {
    "kind": "email",
    "value_raw": "user@example.com",
    "value_canonical": "user@example.com",
    "label": "home",
    "priority": 100,
    "verified": true
  }
]
```

Mapping:

* Directly into `person_identifiers` (`kind`, `value_raw`, `value_canonical`, `label`, `priority`, `verified`).

Rules:

* `value_canonical` must be normalized according to the existing normalization rules (E.164 for phones, lowercased emails, etc.).
* `priority` controls ordering; lower numbers = higher preference.

### 6.3 Relationship to documents

Documents refer to people via `people[].identifier` and `identifier_type`, which must correspond to one or more `Person.identifiers` entries.

* On ingest, Catalog attempts to resolve each `Document.people` entry to a `person_id` via `person_identifiers`.
* Resolution is not stored in the document payload; it is an internal relationship in Catalog and/or materialized views.

Takeaway: `Person` carries the full contact card; `Document.people` carries only the identifiers and roles needed per-document.

---

## 7. Service responsibilities

### 7.1 Haven.app (collectors and enrichment)

Responsibilities:

1. **Normalize into envelopes**

   * Each collector produces either `DocumentEnvelope` or `PersonEnvelope`.
   * Contacts collectors must emit `PersonEnvelope` instead of raw contact structures or `contact` documents.

2. **Map Swift models to transport**

   * `CollectorDocument` + `DocumentMetadata` + `EnrichedDocument` map to `Document.payload`.
   * Swift-side enrichment (OCR, faces via Vision, NER) populates `metadata.attachments` and `metadata.enrichment`.

3. **Apply per-source rules**

   * iMessage: always include a `thread` block and `people` array.
   * Local files: no thread block; attachments describe the file itself.
   * Contacts: emit `Person` and not `Document`.

4. **Avoid schema coupling to Catalog internals**

   * Haven.app does not construct `doc_id`, `thread_id`, or any database primary keys.
   * It only sends external IDs and content; IDs come back in responses.

### 7.2 Gateway

Responsibilities:

1. **Surface v2 endpoints**

   * `POST /v2/ingest/document` – accepts `DocumentEnvelope`.
   * `POST /v2/ingest/person` – accepts `PersonEnvelope`.
   * Accept optional `batch_id` or arrays of envelopes for batch ingestion, mapping to `ingest_batches`.

2. **Validate and enrich**

   * Validate `schema_version`, `kind`, and required fields.
   * Normalize timestamps (UTC, ISO-8601), compute `text_sha256` if missing, and populate `metadata.timestamps.primary` when not present using `content_timestamp`.
   * Compute idempotency keys and insert records in `ingest_submissions`.

3. **Forward unchanged payloads**

   * Forward `payload` (Document or Person) to Catalog without structural modifications, only adding internal headers and idempotency metadata.

4. **Proxy responses**

   * Translate Catalog’s responses into `DocumentIngestResponse` or `PersonIngestResponse` (to be defined) and surface errors with meaningful HTTP status codes.

### 7.3 Catalog

Responsibilities:

1. **Persist Documents**

   * Map `Document.payload` fields into `documents` and related tables (`threads`, `chunks`, `chunk_documents`, `ingest_submissions`).
   * Maintain versioning semantics (`version_number`, `previous_version_id`, `is_active_version`).

2. **Persist People**

   * Map `Person.payload` into `people`, `person_identifiers`, and `people_source_map`.

3. **Maintain threads**

   * Upsert `threads` based on `Document.thread` and update `first_message_at` / `last_message_at`.

4. **Chunking and embedding**

   * Generate `chunks` and `chunk_documents` from `Document.text` and `metadata.attachments`, as already defined.

5. **Return canonical identifiers**

   * Respond to ingestion with the assigned `doc_id`, `person_id` (for persons), `thread_id`, and `submission_id`.

Takeaway: Gateway and Haven.app should be able to evolve independently as long as they respect the `Document` and `Person` schemas.

---

## 8. Versioning and evolution

1. **Envelope schema_version**

   * Used to negotiate breaking changes.
   * v2.0 corresponds to unified schema v2 plus metadata refinements (top-level metadata keys, ingested_at moved to metadata, files table removal).

2. **Backward compatibility**

   * Gateway may continue to accept legacy v1 ingestion formats (`POST /v1/ingest`, `/v1/ingest/file`) and internally transform them into v2 `Document` payloads, but new Haven.app versions should exclusively use v2.

3. **Forward compatibility**

   * New fields must be:

     * Optional.
     * Namespaced under `metadata.*` where possible rather than new top-level columns.

4. **Deprecation**

   * Mark fields as deprecated in the data dictionary before removal; Gateway can log warnings when deprecated fields appear.

---

## 9. Migration notes (from current state)

At a high level:

1. **Define shared models**

   * Implement shared Pydantic models (Python) and Swift structs that mirror `Document` and `Person` payloads exactly.
   * Use the existing data dictionary as the authoritative reference for field types and enums.

2. **Update collectors**

   * iMessage and LocalFS collectors: refactor to emit `DocumentEnvelope` directly instead of gateway-specific payloads.
   * Contacts collector: emit `PersonEnvelope` instead of calling `/catalog/contacts/ingest` with the old format.

3. **Update Gateway**

   * Add `/v2/ingest/document` and `/v2/engest/person` endpoints that accept the envelope and forward as-is to Catalog.
   * Gradually migrate `/v1/ingest` implementations to wrap their payloads into the new schemas.

4. **Update Catalog**

   * Implement `/v2/catalog/documents` and `/v2/catalog/people` endpoints that consume the new schemas and map them to DB tables.

Takeaway: the migration is primarily an API/transport refactor; the underlying schema already matches the proposed structures.

---

## 10. Next steps

1. Define concrete Pydantic / Swift types for:

   * `Envelope` (`schema_version`, `kind`, `source`, `payload`).
   * `Document`, `Person`, `PersonRef`, `ThreadHint`, `DocumentMetadata`, `Attachment`, `Intent`.

2. Update the data dictionary with:

   * Explicit JSON examples for both `DocumentEnvelope` and `PersonEnvelope`.
   * Mapping tables from `CollectorDocument`/Swift structures to `Document` fields.

3. Implement v2 endpoints in Gateway and Catalog and add tests to ensure:

   * Round-trip integrity (no fields lost between Haven.app → Gateway → Catalog).
   * Backward compatibility for existing v1 ingestion flows.
