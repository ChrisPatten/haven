"""In-memory conversation state management for conversational search."""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from typing import Dict, Optional

from shared.logging import get_logger

from .models_v2 import ConversationState, FacetFilter

logger = get_logger("search.conversation")


class ConversationStore:
    """In-memory store for conversation state.
    
    Stores conversation state with TTL cleanup for old conversations.
    Can be upgraded to Redis/Postgres later.
    """

    def __init__(self, ttl_hours: int = 24):
        """Initialize conversation store.
        
        Args:
            ttl_hours: Time-to-live for conversations in hours (default: 24)
        """
        self._store: Dict[str, ConversationState] = {}
        self._ttl = timedelta(hours=ttl_hours)

    def get_conversation(self, conversation_id: str) -> Optional[ConversationState]:
        """Get conversation state by ID.
        
        Args:
            conversation_id: Conversation identifier
            
        Returns:
            ConversationState if found and not expired, None otherwise
        """
        state = self._store.get(conversation_id)
        if state is None:
            return None
        
        # Check if expired
        if datetime.now(timezone.utc) - state.updated_at > self._ttl:
            logger.debug("conversation_expired", conversation_id=conversation_id)
            del self._store[conversation_id]
            return None
        
        return state

    def save_conversation(self, state: ConversationState) -> None:
        """Save conversation state.
        
        Args:
            state: ConversationState to save
        """
        state.updated_at = datetime.now(timezone.utc)
        self._store[state.conversation_id] = state
        logger.debug(
            "conversation_saved",
            conversation_id=state.conversation_id,
            filter_count=len(state.latest_filters),
        )

    def create_conversation(
        self,
        latest_filters: Optional[list[FacetFilter]] = None,
        conversation_metadata: Optional[Dict] = None,
    ) -> ConversationState:
        """Create a new conversation.
        
        Args:
            latest_filters: Optional initial filters
            conversation_metadata: Optional metadata dictionary
            
        Returns:
            New ConversationState
        """
        conversation_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc)
        state = ConversationState(
            conversation_id=conversation_id,
            latest_filters=latest_filters or [],
            conversation_metadata=conversation_metadata or {},
            created_at=now,
            updated_at=now,
        )
        self.save_conversation(state)
        logger.debug("conversation_created", conversation_id=conversation_id)
        return state

    def cleanup_expired(self) -> int:
        """Remove expired conversations.
        
        Returns:
            Number of conversations removed
        """
        now = datetime.now(timezone.utc)
        expired_ids = [
            conv_id
            for conv_id, state in self._store.items()
            if now - state.updated_at > self._ttl
        ]
        for conv_id in expired_ids:
            del self._store[conv_id]
        
        if expired_ids:
            logger.debug("conversations_cleaned", count=len(expired_ids))
        
        return len(expired_ids)


# Global singleton instance
_store = ConversationStore()


def get_conversation_store() -> ConversationStore:
    """Get the global conversation store instance."""
    return _store

