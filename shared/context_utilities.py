from .models_v2 import Document, InferenceContext, Person
from .db import get_document_by_id, resolve_people_from_document, get_thread_messages_from_document, get_batch_thread_documents, resolve_people_from_identifiers, get_self_person_data
from uuid import UUID
from typing import Optional, List, Dict, Any, Tuple
from datetime import datetime

try:
    import pandas as pd
except ImportError:
    pd = None


def get_context_by_document_id(document_id: UUID|str) -> Optional[InferenceContext]:
    """Build a context object for an inference task."""
    if isinstance(document_id, str):
        document_id = UUID(document_id)
    document = get_document_by_id(document_id)
    if document is None:
        return None
    
    sender_name = _get_sender_name(document)

    thread_messages = []
    for message in get_thread_messages_from_document(document):
        thread_sender_name = _get_sender_name(message)
        thread_messages.append((message, thread_sender_name))

    enrichment_entities = _get_enrichment_entities_from_document(document)

    return InferenceContext(
        document=document,
        thread_messages=thread_messages,
        sender=sender_name,
        enrichment_entities=enrichment_entities,
    )

def _normalize_identifier(identifier: Optional[str]) -> Optional[str]:
    """Normalize an identifier by stripping source prefixes.
    
    Documents store identifiers with prefixes like 'E:' for email or 'P:' for phone.
    This strips those prefixes so they match the canonical identifiers in person_identifiers.
    
    Args:
        identifier: Raw identifier from document (e.g., 'E:user@example.com' or 'P:+1234567890')
    
    Returns:
        Canonical identifier without prefix (e.g., 'user@example.com' or '+1234567890')
    """
    if not identifier:
        return None
    
    # Strip common source/type prefixes (E: for email, P: for phone, etc.)
    if ':' in identifier:
        parts = identifier.split(':', 1)
        if len(parts) == 2 and len(parts[0]) == 1:  # Single-letter prefix
            return parts[1]
    
    return identifier


def _get_sender_name_from_people_data(people_data: Optional[List[Dict[str, Any]]], people_lookup: Dict[str, Tuple[Person, str]]) -> Tuple[str, Optional[str]]:
    """Extract sender name and identifier from people JSONB data.
    
    Uses the same logic as _get_sender_name but works with pre-fetched people JSONB data
    and a people lookup dictionary for resolved person information.
    
    Args:
        people_data: List of people JSONB objects from document, each with identifier and role
        people_lookup: Dictionary mapping identifier -> (Person, identifier_value) (resolved from database)
    
    Returns: (sender_name, sender_identifier)
    """
    sender_name = "Unknown Sender"
    sender_identifier = None
    
    if people_data:
        for person in people_data:
            if person.get("role") == "sender":
                raw_identifier = person.get("identifier")
                sender_identifier = _normalize_identifier(raw_identifier)
                
                if sender_identifier and sender_identifier in people_lookup:
                    # Use resolved person's display_name
                    resolved_person, _ = people_lookup[sender_identifier]
                    sender_name = resolved_person.display_name or sender_identifier or "Unknown Sender"
                else:
                    # Fallback to raw identifier if not found in lookup
                    sender_name = raw_identifier or "Unknown Sender"
                break
    
    return sender_name, sender_identifier

def _extract_participants_from_people(people_data: Optional[List[Dict[str, Any]]], people_lookup: Dict[str, Tuple[Person, str]]) -> List[str]:
    """Extract recipient/participant names from people data.
    
    Args:
        people_data: List of people JSONB objects from document, each with identifier and role
        people_lookup: Dictionary mapping identifier -> (Person, identifier_value) (resolved from database)
    """
    participants = []
    
    if people_data:
        for person in people_data:
            if person.get("role") in ("recipient", "to"):
                raw_identifier = person.get("identifier")
                normalized_identifier = _normalize_identifier(raw_identifier)
                
                # Use resolved person's display_name if available, fallback to identifier
                if normalized_identifier and normalized_identifier in people_lookup:
                    resolved_person, _ = people_lookup[normalized_identifier]
                    display_name = resolved_person.display_name or normalized_identifier
                else:
                    display_name = raw_identifier  # Use raw for display if not resolved
                
                if display_name and display_name not in participants:
                    participants.append(display_name)
    
    return participants

def _is_message_valid(text: Optional[str]) -> bool:
    """Check if message text is valid (not metadata/artifacts).
    
    Filters out iMessage metadata attributes like __kIMFileTransferGUIDAttributeName.
    """
    if not text:
        return False
    
    stripped_text = text.strip()
    
    # Skip messages starting with "__"
    if stripped_text.startswith("__"):
        return False
    
    # Skip iMessage internal attributes (e.g., "__kIMFileTransferGUIDAttributeName")
    if stripped_text.startswith('"__') or '__IM' in stripped_text[:50]:
        return False
    
    return True

def extract_ner_from_metadata(metadata: Dict[str, Any]) -> Dict[str, List[str]]:
    """Extract NER entities from document metadata, using entity types as-is from metadata.
    
    Supports both:
    - Legacy metadata.ner format
    - Primary metadata.enrichment.entities format (from enrichment pipeline)
    
    Returns dict mapping entity type -> list of unique entity texts
    """
    ner = {}
    
    # Check for NER metadata (legacy format)
    if "ner" in metadata:
        ner_data = metadata["ner"]
        if isinstance(ner_data, dict):
            for entity_type, values in ner_data.items():
                entity_type_lower = entity_type.lower()
                if entity_type_lower not in ner:
                    ner[entity_type_lower] = []
                # Handle both single values and lists
                entity_values = values if isinstance(values, list) else [values]
                for val in entity_values:
                    if val and val not in ner[entity_type_lower]:
                        ner[entity_type_lower].append(val)
    
    # Also check enrichment entities (primary source)
    if "enrichment" in metadata:
        enrichment = metadata["enrichment"]
        if isinstance(enrichment, dict) and "entities" in enrichment:
            entities = enrichment["entities"]
            if isinstance(entities, list):
                for entity in entities:
                    if isinstance(entity, dict):
                        entity_type = entity.get("type", "").lower()
                        entity_text = entity.get("text", "")
                        if entity_type and entity_text:
                            if entity_type not in ner:
                                ner[entity_type] = []
                            if entity_text not in ner[entity_type]:
                                ner[entity_type].append(entity_text)
    
    return ner

def _get_enrichment_entities_from_document(document: Document) -> List[Dict[str, Any]]:
    """Get the enrichment entities for a document."""
    return document.metadata.get("enrichment", {}).get("entities", [])


def _get_sender_name(message: Document) -> str:
    """Get the sender name for a message."""
    people = resolve_people_from_document(message)
    if not people:
        return "Unknown Sender"

    for person, role in people:
        if role == "sender":
            return person.display_name or "Unknown Sender"
    
    return "Unknown Sender"

def _format_timestamp(timestamp: datetime) -> str:
    """Format a timestamp for a human-readable string."""
    return timestamp.strftime("%Y-%m-%dT%H:%MZ")

def format_context(context: InferenceContext) -> str:
    """Format the context for a human-readable string."""
    output = f"Message:\n{context.sender} at {_format_timestamp(context.document.content_timestamp)} - {context.document.text}\n\n"
    if context.thread_messages:
        output += "Previous Messages:\n"
        for message, sender_name in context.thread_messages:
            output += f"{sender_name} at {_format_timestamp(message.content_timestamp)} - {message.text}\n"
    
    if context.enrichment_entities:
        output += "\n\nDetected Entities:\n"
        for entity in context.enrichment_entities:
            output += f"{entity['text']} - {entity['type']}\n"
    return output

def get_batch_thread_messages(
    as_of: datetime,
    lookback_minutes: int = 60
) -> Optional[Any]:  # Returns pd.DataFrame or list[dict]
    """Query batch of thread documents and format for intent classification.
    
    This is the main replacement for get_messages_from_postgres in thread_batch_processor.py
    
    Args:
        as_of: Query for documents with content_timestamp before this datetime
        lookback_minutes: How far back to look for active threads (by content_timestamp)
    
    Returns:
        DataFrame or list of dicts with columns: thread_id, message_id, author, is_user, 
        timestamp, text, participants, ner
    """
    try:
        # Get self person's data from application settings
        self_person_data = get_self_person_data()
        self_person = None
        user_identifiers = {}  # Maps canonical_identifier -> kind
        if self_person_data:
            self_person, user_identifiers = self_person_data
        
        raw_rows = get_batch_thread_documents(as_of, lookback_minutes)
        
        if not raw_rows:
            print(f"No documents found with content_timestamp before {as_of} (lookback: {lookback_minutes} minutes)")
            return None
        
        # First pass: collect all unique person identifiers that need resolution
        identifiers_to_resolve = set()
        for row in raw_rows:
            _, _, _, _, text, people_data, _, _ = row
            if _is_message_valid(text) and people_data:
                for person in people_data:
                    raw_identifier = person.get("identifier")
                    if raw_identifier:
                        # Normalize by stripping prefixes like E: or P:
                        normalized = _normalize_identifier(raw_identifier)
                        if normalized:
                            identifiers_to_resolve.add(normalized)
        
        # Resolve all identifiers in a single batch query
        people_lookup = resolve_people_from_identifiers(list(identifiers_to_resolve))
        
        # Convert raw rows to formatted message dicts
        messages_data = []
        for row in raw_rows:
            doc_id, external_id, content_ts, ingested_ts, text, people_data, metadata, source_type = row
            
            # Skip invalid messages (metadata artifacts, etc.)
            if not _is_message_valid(text):
                continue
            
            # Extract sender name and participants using resolved people
            author, sender_identifier = _get_sender_name_from_people_data(people_data, people_lookup)
            participants = _extract_participants_from_people(people_data, people_lookup)
            
            # Extract NER from metadata
            ner = extract_ner_from_metadata(metadata or {})
            
            # Determine if this message is from the user by checking against all user identifiers
            is_user_msg = False
            if sender_identifier and user_identifiers:
                # Check if sender's identifier matches any of the user's identifiers (case-insensitive)
                is_user_msg = sender_identifier.lower() in {uid.lower() for uid in user_identifiers.keys()}
            
            # Convert timestamp to pandas Timestamp with UTC timezone
            if pd:
                if isinstance(content_ts, pd.Timestamp):
                    ts = content_ts if content_ts.tz else content_ts.tz_localize('UTC')
                else:
                    ts = pd.Timestamp(content_ts)
                    if ts.tz is None:
                        ts = ts.tz_localize('UTC')
            else:
                ts = content_ts
            
            messages_data.append({
                "thread_id": str(external_id) if external_id else None,
                "message_id": str(doc_id),
                "author": author,
                "is_user": is_user_msg,
                "timestamp": ts,
                "text": text or "",
                "participants": participants,
                "ner": ner
            })
        
        # Return as DataFrame if pandas is available, otherwise as list
        if pd:
            df = pd.DataFrame(messages_data)
            print(f"Loaded {len(df)} documents across {len(df['thread_id'].unique())} threads")
            return df
        else:
            print(f"Loaded {len(messages_data)} documents")
            return messages_data
        
    except Exception as e:
        print(f"Error querying batch thread documents: {e}")
        import traceback
        traceback.print_exc()
        return None