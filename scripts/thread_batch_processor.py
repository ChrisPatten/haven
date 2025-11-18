#!/usr/bin/env python3
"""
Thread-Window Batch Preprocessor for iMessage Intent Detection

This script finds active threads, builds debounced context slices,
caps tokens, merges NER, calls LLM provider (Ollama/OpenAI) for intent classification,
and outputs results to markdown.

Uses the haven_llm module for provider abstraction, supporting both Ollama and OpenAI.

Configuration:
    Configuration can be provided via:
    1. YAML config file (recommended): -c config.yaml
    2. CLI arguments: --llm-provider-type ollama --ollama-model llama3.2
    3. Environment variables: LLM_PROVIDER, OLLAMA_BASE_URL, etc.

    See scripts/thread_batch_processor.example.yaml for a complete example.

Usage:
    # Using YAML config (recommended)
    python scripts/thread_batch_processor.py -c config.yaml
    
    # Using CLI arguments
    python scripts/thread_batch_processor.py --input-data synthetic
    python scripts/thread_batch_processor.py --input-data csv --csv-file messages.csv
    python scripts/thread_batch_processor.py --input-data postgres --as-of "2025-11-12T20:00:00Z"
    
    # Use OpenAI instead of Ollama
    python scripts/thread_batch_processor.py --llm-provider-type openai --input-data synthetic
    
    # Mix YAML config with CLI overrides
    python scripts/thread_batch_processor.py -c config.yaml --llm-provider-type openai
"""

import argparse
import hashlib
import json
import os
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta
from math import ceil
from pathlib import Path
from typing import Dict, List, Optional, Set, Any
import random

import httpx
import pandas as pd
import yaml

# Import database utilities from Haven
try:
    from shared.db import get_connection
    from shared.context_utilities import get_batch_thread_messages
except ImportError:
    print("Warning: shared modules not available; postgres data source disabled")
    get_connection = None
    get_batch_thread_messages = None

# Import LLM provider abstraction
try:
    from shared.haven_llm import (
        get_llm_provider,
        OllamaProvider,
        OllamaSettings,
        OpenAIProvider,
        OpenAISettings,
        LLMProvider,
        LLMProviderError,
    )
except ImportError:
    print("Warning: haven_llm module not available; LLM functionality disabled")
    get_llm_provider = None
    OllamaProvider = None
    OpenAIProvider = None

os.environ["DATABASE_URL"] = "postgresql://postgres:postgres@localhost:5432/haven"

# ---------------------------------------------------------------------------  
# Data Models
# ---------------------------------------------------------------------------

@dataclass
class MessageLite:
    thread_id: str
    message_id: str
    author: str
    is_user: bool
    timestamp: pd.Timestamp
    text: str
    ner: Dict[str, Any]

@dataclass
class ThreadSlice:
    thread_id: str
    start_ts: pd.Timestamp
    end_ts: pd.Timestamp
    messages: List[MessageLite]
    group_size: int
    participants: List[str]
    slice_hash: str
    token_est: int
    has_signals: bool

@dataclass
class LLMIntentRequest:
    thread_id: str
    slice_hash: str
    thread_meta: Dict[str, Any]
    conversation: List[Dict[str, Any]]
    ner_overlay: Dict[str, Any]
    allowed_intents: List[str]
    token_est: int

@dataclass
class IntentResult:
    thread_id: str
    slice_hash: str
    classification: Dict[str, Any]
    raw_ollama_response: str
    processing_time_ms: float
    prompt: str  # The actual prompt sent to the model


# ---------------------------------------------------------------------------  
# Helper Functions
# ---------------------------------------------------------------------------

def estimate_tokens(text: str) -> int:
    """Simple heuristic: tokens ≈ ceil(len(text) / 4)."""
    return ceil(len(text) / 4)

def build_ner_overlay(messages: List[MessageLite]) -> Dict[str, List[str]]:
    """Union and de-dup NER entities across all messages.
    Collects all entity types present in any message and aggregates them.
    """
    overlay = {}
    
    for msg in messages:
        if msg.ner and isinstance(msg.ner, dict):
            for entity_type, entities in msg.ner.items():
                if entity_type not in overlay:
                    overlay[entity_type] = []
                if isinstance(entities, list):
                    overlay[entity_type].extend(entities)
    
    # De-dupe and sort each entity type
    for entity_type in overlay:
        overlay[entity_type] = sorted(list(set(overlay[entity_type])))
    
    return overlay

def has_action_keyword(text: str, lex: Set[str]) -> bool:
    """Check if text contains any action keyword (case-insensitive)."""
    text_lower = text.lower()
    return any(keyword in text_lower for keyword in lex)

def compute_slice_hash(messages: List[MessageLite]) -> str:
    """Generate stable hash: sha256 over "\n".join(f"{m.message_id}|{m.timestamp.value}|{m.text}")."""
    content = "\n".join(f"{m.message_id}|{m.timestamp.value}|{m.text}" for m in messages)
    return hashlib.sha256(content.encode('utf-8')).hexdigest()


# ---------------------------------------------------------------------------  
# Batch Discovery
# ---------------------------------------------------------------------------

def get_active_threads(msgs: pd.DataFrame, now: pd.Timestamp, active_thread_window_minutes: int) -> Set[str]:
    """Any thread with a message timestamp ≥ now - active_thread_window_minutes."""
    cutoff = now - pd.Timedelta(minutes=active_thread_window_minutes)
    active = msgs[msgs['timestamp'] >= cutoff]['thread_id'].unique()
    return set(active)


# ---------------------------------------------------------------------------  
# Slice Builder (Core)
# ---------------------------------------------------------------------------

def build_thread_slice(
    msgs: pd.DataFrame,
    thread_id: str,
    now: pd.Timestamp,
    thread_context_window_minutes: int,
    max_messages_per_slice: int,
    debounce_s: int,
    participants_max: int,
    token_budget: int,
    k_recent: int,
    action_lexicon: Set[str]
) -> Optional[ThreadSlice]:
    """Build a thread slice with debouncing, trimming, and token budgeting."""
    
    # Pull messages in [now - thread_context_window_minutes, now] for that thread; sort ascending
    cutoff = now - pd.Timedelta(minutes=thread_context_window_minutes)
    thread_msgs = msgs[
        (msgs['thread_id'] == thread_id) & 
        (msgs['timestamp'] >= cutoff) & 
        (msgs['timestamp'] <= now)
    ].sort_values('timestamp', ignore_index=False)
    
    if thread_msgs.empty:
        return None
    
    # Get thread participants (should be consistent across messages)
    participants = thread_msgs.iloc[0]['participants']
    group_size = len(set(thread_msgs['author'].unique()) | set(participants))
    
    # Check debounce: if most recent message ts ≥ now - debounce_s: return None
    most_recent = thread_msgs['timestamp'].max()
    if most_recent >= now - pd.Timedelta(seconds=debounce_s):
        return None
    
    # Convert to MessageLite objects
    messages = []
    for _, row in thread_msgs.iterrows():
        ts = row['timestamp']
        # Ensure timestamp is timezone-aware
        if isinstance(ts, pd.Timestamp):
            if ts.tz is None:
                ts = ts.tz_localize('UTC')
        else:
            ts = pd.Timestamp(ts, tz='UTC')
        messages.append(MessageLite(
            thread_id=str(row['thread_id']),
            message_id=str(row['message_id']),
            author=str(row['author']),
            is_user=bool(row['is_user']),
            timestamp=ts,
            text=str(row['text']),
            ner=row.get('ner', {}) if isinstance(row.get('ner'), dict) else {}
        ))
    
    # Build NER overlay and check for signals
    ner_overlay = build_ner_overlay(messages)
    concatenated_text = ' '.join(m.text for m in messages)
    has_signals = (
        len(ner_overlay.get('dates', [])) > 0 or
        len(ner_overlay.get('money', [])) > 0 or
        has_action_keyword(concatenated_text, action_lexicon)
    )
    
    # Skip large groups without signals
    if group_size > participants_max and not has_signals:
        return None
    
    # Trim messages if needed
    if len(messages) > max_messages_per_slice:
        # Keep newest k_recent
        recent_messages = messages[-k_recent:]
        
        # Also keep older signal messages
        signal_messages = []
        for msg in messages[:-k_recent]:  # older messages
            if (
                len(msg.ner.get('dates', [])) > 0 or
                len(msg.ner.get('money', [])) > 0 or
                has_action_keyword(msg.text, action_lexicon)
            ):
                signal_messages.append(msg)
        
        # Combine and sort chronologically
        messages = sorted(signal_messages + recent_messages, key=lambda m: m.timestamp)
    
    # Token budgeting
    total_text = ' '.join(m.text for m in messages)
    token_est = estimate_tokens(total_text)
    
    if token_est > token_budget:
        # Keep newest k_recent always
        keep_messages = messages[-k_recent:]
        remaining_budget = token_budget - estimate_tokens(' '.join(m.text for m in keep_messages))
        
        # Add older messages while staying under budget, preferring signal messages
        older_messages = messages[:-k_recent]
        
        # Sort older messages by priority: signals first, then chronological
        signal_older = [m for m in older_messages if (
            len(m.ner.get('dates', [])) > 0 or
            len(m.ner.get('money', [])) > 0 or
            has_action_keyword(m.text, action_lexicon)
        )]
        non_signal_older = [m for m in older_messages if m not in signal_older]
        
        # Add signal messages first (newest first within signals)
        signal_older_sorted = sorted(signal_older, key=lambda m: m.timestamp, reverse=True)
        for msg in signal_older_sorted:
            msg_tokens = estimate_tokens(msg.text)
            if remaining_budget >= msg_tokens:
                keep_messages.insert(0, msg)  # Insert at beginning to maintain chronological order later
                remaining_budget -= msg_tokens
            else:
                break
        
        # Add non-signal messages if budget allows (newest first)
        non_signal_older_sorted = sorted(non_signal_older, key=lambda m: m.timestamp, reverse=True)
        for msg in non_signal_older_sorted:
            msg_tokens = estimate_tokens(msg.text)
            if remaining_budget >= msg_tokens:
                keep_messages.insert(0, msg)
                remaining_budget -= msg_tokens
            else:
                break
        
        # Sort chronologically and update token estimate
        messages = sorted(keep_messages, key=lambda m: m.timestamp)
        total_text = ' '.join(m.text for m in messages)
        token_est = estimate_tokens(total_text)
    
    # Generate slice hash
    slice_hash = compute_slice_hash(messages)
    
    if messages:
        start_ts = messages[0].timestamp
    else:
        start_ts = now - pd.Timedelta(minutes=thread_context_window_minutes)
        if start_ts.tz is None:
            start_ts = start_ts.tz_localize('UTC')
    
    # Ensure end_ts is timezone-aware
    if isinstance(most_recent, pd.Timestamp):
        end_ts = most_recent if most_recent.tz else most_recent.tz_localize('UTC')
    elif isinstance(most_recent, datetime):
        end_ts = pd.Timestamp(most_recent)
        if end_ts.tz is None:
            end_ts = end_ts.tz_localize('UTC')
    else:
        end_ts = pd.Timestamp(most_recent, tz='UTC')
    
    return ThreadSlice(
        thread_id=thread_id,
        start_ts=start_ts,
        end_ts=end_ts,
        messages=messages,
        group_size=group_size,
        participants=participants,
        slice_hash=slice_hash,
        token_est=token_est,
        has_signals=has_signals
    )


# ---------------------------------------------------------------------------  
# Request Assembly
# ---------------------------------------------------------------------------

def make_llm_request(slice: ThreadSlice, allowed_intents: List[str], user_name: Optional[str] = None) -> LLMIntentRequest:
    """Convert slice to LLM request format."""
    
    thread_meta = {
        'thread_id': slice.thread_id,
        'group_size': slice.group_size,
        'participants': slice.participants
    }
    
    conversation = [
        {
            'id': msg.message_id,
            'author': msg.author,
            'is_user': msg.is_user,
            'user_name': user_name if msg.is_user else None,  # Include user_name for user messages
            'ts_iso': msg.timestamp.isoformat(),
            'text': msg.text
        }
        for msg in slice.messages
    ]
    
    ner_overlay = build_ner_overlay(slice.messages)
    
    return LLMIntentRequest(
        thread_id=slice.thread_id,
        slice_hash=slice.slice_hash,
        thread_meta=thread_meta,
        conversation=conversation,
        ner_overlay=ner_overlay,
        allowed_intents=allowed_intents,
        token_est=slice.token_est
    )


# ---------------------------------------------------------------------------  
# LLM Provider Integration
# ---------------------------------------------------------------------------

def initialize_llm_provider(config: Dict[str, Any]) -> Optional[LLMProvider]:
    """Initialize LLM provider from configuration.
    
    Supports both new LLM provider abstraction and legacy Ollama settings.
    Configuration priority:
    1. llm_provider_type + provider-specific settings (new way)
    2. ollama_url + ollama_model (legacy, backward compatible)
    
    Args:
        config: Configuration dictionary
    
    Returns:
        LLMProvider instance or None if initialization fails
    """
    if get_llm_provider is None or OllamaProvider is None or OpenAIProvider is None:
        print("Error: haven_llm module not available")
        return None
    
    # New way: explicit provider type
    provider_type = config.get('llm_provider_type', None)
    
    if provider_type:
        if provider_type == 'ollama':
            settings = OllamaSettings(
                base_url=config.get('ollama_base_url', 'http://localhost:11434'),
                model=config.get('ollama_model', 'llama3.2'),
                timeout=config.get('llm_timeout', 60.0),
            )
            return OllamaProvider(settings=settings)
        elif provider_type == 'openai':
            settings = OpenAISettings(
                model=config.get('openai_model', 'gpt-4'),
                temperature=config.get('openai_temperature', 0.7),
                max_tokens=config.get('openai_max_tokens', None),
                timeout=config.get('llm_timeout', 60.0),
            )
            return OpenAIProvider(settings=settings)
        else:
            # Use factory function with environment variables
            return get_llm_provider(provider_type=provider_type)
    
    # Legacy way: backward compatibility with ollama_url/ollama_model
    if 'ollama_url' in config or 'ollama_model' in config:
        settings = OllamaSettings(
            base_url=config.get('ollama_url', 'http://localhost:11434'),
            model=config.get('ollama_model', 'llama3.2:latest'),
            timeout=config.get('llm_timeout', 60.0),
        )
        return OllamaProvider(settings=settings)
    
    # Default: auto-detect from environment
    return get_llm_provider()

def build_intent_prompt(request: LLMIntentRequest) -> str:
    """Build the intent classification prompt for LLM providers."""
    
    taxonomy_info = """Available intents:
- commitment.create: Capture a commitment or promise that the user offered or agreed to. Slots: what (string, required), due_date (datetime, optional), for_whom (person, optional), source_ref (string, required).
- task.create: Create a new task or to-do item that the user wants to track. Slots: what (string, required), due_date (datetime, optional), assignee (person, optional), source_ref (string, required).
- schedule.create: Schedule a calendar event, meeting, appointment, block, or anything else that needs to be added to the calendar. Slots: start_dt (datetime, required), end_dt (datetime, optional), location (location, optional), participants (array[person], optional), title (string, optional), source_ref (string, required).
- reminder.create: Create a reminder or follow-up notification for the user. Slots: what (string, required), remind_at (datetime, optional), person (person, optional), source_ref (string, required)."""

    entities_json = json.dumps(request.ner_overlay, indent=2)
    
    # Build conversation text with user indicator and timestamps
    conversation_parts = []
    for msg in request.conversation:
        author = msg['author']
        is_user = msg.get('is_user', False)
        user_name = msg.get('user_name')
        text = msg['text']
        ts_iso = msg.get('ts_iso', '')
        
        # Parse and reformat timestamp to "YYYY-MM-DD HH:MMZ" format
        timestamp_str = ''
        if ts_iso:
            try:
                # Parse ISO format and reformat to "2025-11-13 19:02Z"
                dt = datetime.fromisoformat(ts_iso.replace('Z', '+00:00'))
                timestamp_str = f" [{dt.strftime('%Y-%m-%d %H:%M')}Z]"
            except Exception:
                pass
        
        # Mark messages from the user with [USER] prefix, using user_name if available
        if is_user:
            display_name = user_name if user_name else author
            conversation_parts.append(f"[USER] {display_name}{timestamp_str}: {text}")
        else:
            conversation_parts.append(f"{author}{timestamp_str}: {text}")
    
    conversation_text = "\n-----\n".join(conversation_parts)
    
    prompt = f"""You are an intent classification assistant. Given the following artifact text, extracted entities, and conversation context, identify which intents (if any) from the provided taxonomy are present.
There may not be any intents present. There may be multiple intents present.

Note: Messages marked with [USER] are from the user (the person whose intents you are classifying). Others are from other participants.

Return a JSON object with this structure:
{{
  "intents": [
    {{
      "name": "<intent_name>",
      "title": "<title/name of what will be created>",
      "details": "<2-3 sentence explanation of the intent context and what needs to be done>",
      "base_confidence": 0.0-1.0,
      "reasons": ["detailed explanation of why this intent matches"]
    }}
  ],
  "notes": ["optional explanatory notes"]
}}

Guidelines:
- Only include intents whose confidence is at least 0.35.
- Confidence values must be floats between 0 and 1.
- Use multi-label classification (zero or more intents may apply).
- For each intent:
  * "title": The title/name of what will be created (e.g., "Team Standup" for a meeting, "Buy groceries" for a task, "Call mom" for a reminder)
  * "details": Provide context about what needs to be done, extracted dates/times, participants, or any other relevant information
  * "reasons": Detailed reasons explaining WHY it matches:
    - Quote specific phrases from the text that indicate this intent
    - Explain semantic patterns (e.g., 'remember to' suggests reminder.create)
    - Note any contextual clues from channel metadata or conversation history
    - Do NOT just list slot names - explain the reasoning
- Consider conversation context when resolving ambiguous references.

Taxonomy version: 1.0.0
{taxonomy_info}

Entities (JSON):
{entities_json}

Current artifact text:
-----
{conversation_text}
-----

Return your response as a valid JSON object."""
    
    return prompt

def call_llm_intent_classification(
    request: LLMIntentRequest,
    llm_provider: LLMProvider,
    model: Optional[str] = None,
) -> IntentResult:
    """Call LLM provider for intent classification using the haven_llm abstraction.
    
    Args:
        request: The intent classification request with thread data
        llm_provider: LLM provider instance (from haven_llm module)
        model: Optional model override (uses provider default if None)
    
    Returns:
        IntentResult with classification results
    """
    import time
    
    start_time = time.time()
    prompt = build_intent_prompt(request)
    
    try:
        # Use the LLM provider abstraction
        llm_response = llm_provider.generate(
            prompt=prompt,
            model=model,
            format="json",
        )
        
        raw_response = llm_response.text
        
        # Parse the JSON response
        try:
            classification = json.loads(raw_response)
        except json.JSONDecodeError:
            classification = {"error": "Failed to parse JSON response", "raw": raw_response}
        
        processing_time = (time.time() - start_time) * 1000  # ms
        
        return IntentResult(
            thread_id=request.thread_id,
            slice_hash=request.slice_hash,
            classification=classification,
            raw_ollama_response=raw_response,  # Keep field name for backward compatibility
            processing_time_ms=processing_time,
            prompt=prompt
        )
        
    except LLMProviderError as e:
        processing_time = (time.time() - start_time) * 1000
        return IntentResult(
            thread_id=request.thread_id,
            slice_hash=request.slice_hash,
            classification={"error": f"LLM provider error: {str(e)}"},
            raw_ollama_response="",
            processing_time_ms=processing_time,
            prompt=prompt
        )
    except Exception as e:
        processing_time = (time.time() - start_time) * 1000
        return IntentResult(
            thread_id=request.thread_id,
            slice_hash=request.slice_hash,
            classification={"error": f"Unexpected error: {str(e)}"},
            raw_ollama_response="",
            processing_time_ms=processing_time,
            prompt=prompt if 'prompt' in locals() else ""
        )


# ---------------------------------------------------------------------------  
# Batch Driver
# ---------------------------------------------------------------------------

def run_batch(
    msgs: pd.DataFrame,
    now: pd.Timestamp,
    config: Dict[str, Any]
) -> Dict[str, Any]:
    """Orchestrate the entire batch processing."""
    
    # Extract config with defaults
    active_thread_window_minutes = config.get('active_thread_window_minutes', 3)  # batch cadence window
    thread_context_window_minutes = config.get('thread_context_window_minutes', 45)  # lookback context window
    max_messages_per_slice = config.get('max_messages_per_slice', 25)  # max messages per slice
    debounce_s = config.get('debounce_s', 120)  # defer if too fresh
    participants_max = config.get('participants_max', 7)
    token_budget = config.get('token_budget', 4000)
    k_recent = config.get('k_recent', 12)
    canary_rate = config.get('canary_rate', 0.03)
    max_threads_per_batch = config.get('max_threads_per_batch', 15)
    user_name = config.get('user_name')  # Display name for the user in prompts
    exclude_thread_ids = set(config.get('exclude_thread_ids', []))  # Convert to set for O(1) lookup
    allowed_intents = config.get('allowed_intents', ["commitment.create", "task.create", "schedule.create", "reminder.create", "contact.update", "gift.occasion"])
    action_lexicon = set(config.get('action_lexicon', ["schedule", "book", "reserve", "remind", "follow up", "confirm", "call", "meet", "pay", "due", "by ", "at ", "tomorrow", "next ", "pickup", "pick up", "drop off"]))
    
    # Initialize metrics
    metrics = {
        'seen_threads': 0,
        'excluded': 0,
        'considered': 0,
        'deferred_debounce': 0,
        'skipped_large_group_no_signal': 0,
        'over_budget_trimmed': 0,
        'dedup_skips': 0,
        'ready_count': 0,
        'sampled_count': 0,
        'avg_tokens': 0
    }
    
    # Get active threads
    active_threads = get_active_threads(msgs, now, active_thread_window_minutes)
    metrics['seen_threads'] = len(active_threads)
    
    # Filter out excluded threads
    active_threads = [tid for tid in active_threads if tid not in exclude_thread_ids]
    metrics['excluded'] = metrics['seen_threads'] - len(active_threads)
    
    # Debug: show timestamp range in data
    min_ts = msgs['timestamp'].min()
    max_ts = msgs['timestamp'].max()
    print(f"\n[DEBUG] Batch Processing Diagnostics:")
    print(f"  Total messages in dataset: {len(msgs)}")
    print(f"  Timestamp range: {min_ts} to {max_ts}")
    print(f"  Current 'now': {now}")
    print(f"  Active thread window ({active_thread_window_minutes} min): {now - pd.Timedelta(minutes=active_thread_window_minutes)} to {now}")
    print(f"  Active threads found: {metrics['seen_threads']}")
    if metrics['seen_threads'] == 0:
        print(f"  WARNING: No active threads found! Messages may be outside the {active_thread_window_minutes} minute window.")
    
    candidates = []
    skipped_pool = []
    
    # Process each thread
    for thread_id in active_threads:
        slice_obj = build_thread_slice(
            msgs, thread_id, now, thread_context_window_minutes, max_messages_per_slice, debounce_s, participants_max,
            token_budget, k_recent, action_lexicon
        )
        
        if slice_obj is None:
            # Check why it was skipped
            thread_data = msgs[msgs['thread_id'] == thread_id]
            if not thread_data.empty:
                most_recent = thread_data['timestamp'].max()
                if most_recent >= now - pd.Timedelta(seconds=debounce_s):
                    metrics['deferred_debounce'] += 1
                else:
                    participants = thread_data.iloc[0]['participants']
                    group_size = len(set(thread_data['author'].unique()) | set(participants))
                    if group_size > participants_max:
                        metrics['skipped_large_group_no_signal'] += 1
            skipped_pool.append(thread_id)
            continue
        
        metrics['considered'] += 1
        
        # Check for deduplication
        if last_slice_hash_by_thread.get(thread_id) == slice_obj.slice_hash:
            metrics['dedup_skips'] += 1
            continue
        
        candidates.append(slice_obj)
    
    # Sort candidates: prioritize 1:1 threads, then those with signals
    candidates.sort(key=lambda s: (s.group_size > 2, not s.has_signals))
    
    # Take up to max_threads_per_batch as ready
    ready_slices = candidates[:max_threads_per_batch]
    ready_requests = [make_llm_request(slice, allowed_intents, user_name) for slice in ready_slices]
    
    # Debug: show filtering chain
    print(f"\n[DEBUG] Filtering Chain:")
    print(f"  Seen threads: {metrics['seen_threads']}")
    print(f"  Considered (built slices): {metrics['considered']}")
    print(f"  Deferred (debounce): {metrics['deferred_debounce']}")
    print(f"  Skipped (large group, no signal): {metrics['skipped_large_group_no_signal']}")
    print(f"  Candidates after filtering: {len(candidates)}")
    print(f"  Ready requests (to send to Ollama): {len(ready_requests)}")
    
    # Update hash tracking
    for slice_obj in ready_slices:
        last_slice_hash_by_thread[slice_obj.thread_id] = slice_obj.slice_hash
    
    # Sample from skipped pool for canary
    sample_size = int(len(skipped_pool) * canary_rate)
    sampled_thread_ids = random.sample(skipped_pool, min(sample_size, len(skipped_pool)))
    
    sampled_requests = []
    for thread_id in sampled_thread_ids:
        slice_obj = build_thread_slice(
            msgs, thread_id, now, thread_context_window_minutes, max_messages_per_slice, debounce_s, participants_max,
            token_budget, k_recent, action_lexicon
        )
        if slice_obj:
            sampled_requests.append(make_llm_request(slice_obj, allowed_intents, user_name))
    
    # Update metrics
    metrics['ready_count'] = len(ready_requests)
    metrics['sampled_count'] = len(sampled_requests)
    
    # Calculate average tokens for ready requests
    if ready_requests:
        total_tokens = sum(req.token_est for req in ready_requests)
        metrics['avg_tokens'] = int(total_tokens / len(ready_requests))
    
    return {
        'ready': ready_requests,
        'sampled': sampled_requests,
        'metrics': metrics
    }


# ---------------------------------------------------------------------------  
# Database Querying
# ---------------------------------------------------------------------------

def get_messages_from_postgres(as_of: datetime, lookback_minutes: int = 60) -> Optional[pd.DataFrame]:
    """Query Postgres for messages/documents since as_of timestamp within lookback window.
    
    This function delegates to shared.context_utilities.get_batch_thread_messages for the actual
    querying and processing logic. User identification is determined from application settings.
    
    Args:
        as_of: Query for documents with content_timestamp before this datetime
        lookback_minutes: How far back to look for active threads (by content_timestamp)
    
    Returns:
        DataFrame with columns: thread_id, message_id, author, is_user, timestamp, text, participants, ner
    """
    if get_batch_thread_messages is None:
        print("Error: Postgres support not available. Make sure 'shared' is in PYTHONPATH")
        return None
    
    return get_batch_thread_messages(as_of, lookback_minutes)


# ---------------------------------------------------------------------------  
# Synthetic Data Generation
# ---------------------------------------------------------------------------

def create_synthetic_data() -> pd.DataFrame:
    """Create synthetic test dataset."""
    now = pd.Timestamp.now(tz='UTC')
    
    # Thread 1: 1:1 thread with scheduling intent
    thread1_id = "thread_1on1_schedule"
    thread1_data = {
        'thread_id': [thread1_id] * 3,
        'message_id': [f'msg_{i}' for i in range(3)],
        'author': ['alice', 'bob', 'alice'],
        'is_user': [False, True, False],
        'timestamp': [
            now - pd.Timedelta(minutes=30),
            now - pd.Timedelta(minutes=25),
            now - pd.Timedelta(minutes=20)
        ],
        'text': [
            'Hey, how are you doing?',
            'Good, but busy. Can you schedule the plumber next Tuesday at 9am?',
            'Sure, I can do that for you.'
        ],
        'participants': [['alice', 'bob']] * 3,
        'ner': [
            {},
            {'dates': ['2025-11-12T09:00:00'], 'people': ['plumber']},
            {}
        ]
    }
    
    # Thread 2: Large group chat with no signals (should be skipped)
    thread2_id = "thread_large_group"
    participants_large = [f'person_{i}' for i in range(10)]
    thread2_data = {
        'thread_id': [thread2_id] * 2,
        'message_id': [f'group_msg_{i}' for i in range(2)],
        'author': ['person_1', 'person_2'],
        'is_user': [False, False],
        'timestamp': [
            now - pd.Timedelta(minutes=15),
            now - pd.Timedelta(minutes=10)
        ],
        'text': [
            'Hey everyone, what\'s up?',
            'Not much, just hanging out.'
        ],
        'participants': [participants_large] * 2,
        'ner': [{}, {}]
    }
    
    # Thread 3: Busy 1:1 thread with many messages (should trim)
    thread3_id = "thread_busy_1on1"
    thread3_messages = []
    for i in range(35):  # More than K=25
        thread3_messages.append({
            'thread_id': thread3_id,
            'message_id': f'busy_msg_{i}',
            'author': 'charlie' if i % 2 == 0 else 'diana',
            'is_user': i % 2 == 1,
            'timestamp': now - pd.Timedelta(minutes=50 - i),  # Spread over time
            'text': f'Message {i}: {"I need to schedule a meeting tomorrow" if i == 10 else "Regular chat"}',
            'participants': ['charlie', 'diana'],
            'ner': {'dates': ['tomorrow']} if i == 10 else {}
        })
    
    # Combine all threads
    all_data = thread1_data['thread_id'] + thread2_data['thread_id'] + [m['thread_id'] for m in thread3_messages]
    all_msg_ids = thread1_data['message_id'] + thread2_data['message_id'] + [m['message_id'] for m in thread3_messages]
    all_authors = thread1_data['author'] + thread2_data['author'] + [m['author'] for m in thread3_messages]
    all_is_user = thread1_data['is_user'] + thread2_data['is_user'] + [m['is_user'] for m in thread3_messages]
    all_timestamps = thread1_data['timestamp'] + thread2_data['timestamp'] + [m['timestamp'] for m in thread3_messages]
    all_texts = thread1_data['text'] + thread2_data['text'] + [m['text'] for m in thread3_messages]
    all_participants = thread1_data['participants'] + thread2_data['participants'] + [m['participants'] for m in thread3_messages]
    all_ner = thread1_data['ner'] + thread2_data['ner'] + [m['ner'] for m in thread3_messages]
    
    # Create DataFrame
    msgs = pd.DataFrame({
        'thread_id': all_data,
        'message_id': all_msg_ids,
        'author': all_authors,
        'is_user': all_is_user,
        'timestamp': all_timestamps,
        'text': all_texts,
        'participants': all_participants,
        'ner': all_ner
    })
    
    return msgs


# ---------------------------------------------------------------------------  
# Markdown Output
# ---------------------------------------------------------------------------

def generate_markdown_report(
    batch_result: Dict[str, Any],
    intent_results: List[IntentResult],
    config: Dict[str, Any],
    llm_requests: Optional[List[LLMIntentRequest]] = None
) -> str:
    """Generate markdown report of batch processing results."""
    
    lines = []
    lines.append("# Thread Batch Processor Results")
    lines.append("")
    lines.append(f"Generated: {datetime.now().isoformat()}")
    lines.append("")
    
    # Metrics
    lines.append("## Batch Processing Metrics")
    lines.append("")
    metrics = batch_result['metrics']
    lines.append(f"- **Seen Threads**: {metrics['seen_threads']}")
    lines.append(f"- **Considered Threads**: {metrics['considered']}")
    lines.append(f"- **Deferred (Debounce)**: {metrics['deferred_debounce']}")
    lines.append(f"- **Skipped (Large Group, No Signals)**: {metrics['skipped_large_group_no_signal']}")
    lines.append(f"- **Dedup Skips**: {metrics['dedup_skips']}")
    lines.append(f"- **Ready Requests**: {metrics['ready_count']}")
    lines.append(f"- **Sampled Requests**: {metrics['sampled_count']}")
    lines.append(f"- **Average Tokens**: {metrics['avg_tokens']:.1f}")
    lines.append("")
    
    # Intent Classification Results
    lines.append("## Intent Classification Results")
    lines.append("")
    
    for i, result in enumerate(intent_results, 1):
        lines.append(f"### Thread {i}: {result.thread_id}")
        lines.append("")
        lines.append(f"- **Slice Hash**: `{result.slice_hash}`")
        lines.append(f"- **Processing Time**: {result.processing_time_ms:.1f}ms")
        lines.append("")
        
        # Show the actual prompt sent to the model
        lines.append("**Prompt Sent to Model:**")
        lines.append("")
        lines.append("```")
        lines.append(result.prompt)
        lines.append("```")
        lines.append("")
        
        if "error" in result.classification:
            lines.append("❌ **Error**: " + result.classification["error"])
        else:
            # Intents
            intents = result.classification.get("intents", [])
            if intents:
                lines.append("**Detected Intents:**")
                for intent in intents:
                    confidence = intent.get("base_confidence", 0) * 100
                    lines.append(f"- **{intent['name']}** ({confidence:.1f}%)")
                    if intent.get("reasons"):
                        for reason in intent["reasons"]:
                            lines.append(f"  - {reason}")
            else:
                lines.append("**No intents detected**")
            
            # Notes
            notes = result.classification.get("notes", [])
            if notes:
                lines.append("")
                lines.append("**Notes:**")
                for note in notes:
                    lines.append(f"- {note}")
        
        lines.append("")
        lines.append("**Raw Ollama Response:**")
        lines.append("")
        lines.append("```json")
        lines.append(result.raw_ollama_response)
        lines.append("```")
        lines.append("")
    
    return "\n".join(lines)


# ---------------------------------------------------------------------------  
# Main Script
# ---------------------------------------------------------------------------

def main():
    # Get project root for relative paths
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    
    # Default configuration
    default_config = {
        'active_thread_window_minutes': 3,
        'thread_context_window_minutes': 45,
        'max_messages_per_slice': 25,
        'debounce_s': 120,
        'participants_max': 7,
        'token_budget': 4000,
        'k_recent': 12,
        'canary_rate': 0.03,
        'max_threads_per_batch': 15,
        'input_data': 'synthetic',
        'csv_file': None,
        'as_of': None,
        'lookback_minutes': 60,
        'output': str(project_root / ".tmp" / "thread_batch_results.md"),
        # LLM provider settings (new way)
        'llm_provider_type': None,  # 'ollama' or 'openai' (None = auto-detect from env)
        'ollama_base_url': 'http://localhost:11434',
        'ollama_model': 'llama3.2:latest',
        'openai_model': 'gpt-4',
        'openai_temperature': 0.7,
        'openai_max_tokens': None,
        'llm_timeout': 60.0,
        # Legacy Ollama settings (backward compatible)
        'ollama_url': 'http://localhost:11434',
        'user_name': None,  # Display name for the user in prompts (e.g., 'Chris')
        'exclude_thread_ids': [],  # List of thread IDs to exclude from processing
        'allowed_intents': ["commitment.create", "task.create", "schedule.create", "reminder.create", "contact.update", "gift.occasion"],
        'action_lexicon': ["schedule", "book", "reserve", "remind", "follow up", "confirm", "call", "meet", "pay", "due", "by ", "at ", "tomorrow", "next ", "pickup", "pick up", "drop off"]
    }
    
    parser = argparse.ArgumentParser(description="Thread-Window Batch Preprocessor for iMessage Intent Detection")
    parser.add_argument(
        "-c", "--config-file",
        type=str,
        help="YAML config file path (optional). CLI arguments override config values."
    )
    
    # Automatically generate CLI arguments for all config options
    for key, default_value in default_config.items():
        # Convert snake_case to kebab-case for CLI argument names
        cli_arg_name = '--' + key.replace('_', '-')
        
        # Determine the appropriate type and handler
        if isinstance(default_value, bool):
            parser.add_argument(
                cli_arg_name,
                action='store_true' if not default_value else 'store_false',
                help=f"Config: {key}"
            )
        elif isinstance(default_value, int):
            parser.add_argument(
                cli_arg_name,
                type=int,
                help=f"Config: {key}"
            )
        elif isinstance(default_value, float):
            parser.add_argument(
                cli_arg_name,
                type=float,
                help=f"Config: {key}"
            )
        elif isinstance(default_value, list):
            parser.add_argument(
                cli_arg_name,
                nargs='+',
                help=f"Config: {key} (space-separated list)"
            )
        elif key == 'input_data':
            # Special handling for input_data with choices
            parser.add_argument(
                cli_arg_name,
                choices=['synthetic', 'csv', 'postgres'],
                help=f"Config: {key}"
            )
        else:
            # Default to string
            parser.add_argument(
                cli_arg_name,
                type=str,
                help=f"Config: {key}"
            )
    
    args = parser.parse_args()
    
    # Load configuration from YAML file if provided
    config = default_config.copy()
    if args.config_file and Path(args.config_file).exists():
        with open(args.config_file, 'r') as f:
            file_config = yaml.safe_load(f) or {}
            # Force action_lexicon values to be strings if present
            if 'action_lexicon' in file_config and isinstance(file_config['action_lexicon'], list):
                file_config['action_lexicon'] = [str(item) for item in file_config['action_lexicon']]
            config.update(file_config)
            print(f"Loaded configuration from: {args.config_file}")
            
            # Show LLM provider settings if configured
            if 'llm_provider_type' in file_config:
                print(f"  LLM Provider: {file_config['llm_provider_type']}")
                if file_config['llm_provider_type'] == 'ollama':
                    if 'ollama_model' in file_config:
                        print(f"    Model: {file_config['ollama_model']}")
                    if 'ollama_base_url' in file_config:
                        print(f"    Base URL: {file_config['ollama_base_url']}")
                elif file_config['llm_provider_type'] == 'openai':
                    if 'openai_model' in file_config:
                        print(f"    Model: {file_config['openai_model']}")
            elif 'ollama_url' in file_config or 'ollama_model' in file_config:
                print(f"  LLM Provider: ollama (legacy config)")
                if 'ollama_model' in file_config:
                    print(f"    Model: {file_config['ollama_model']}")
    elif args.config_file:
        print(f"Warning: Config file not found: {args.config_file}")
    
    # Automatically override config with CLI arguments (only if explicitly provided)
    for key in default_config.keys():
        # Convert snake_case back for attribute lookup
        cli_attr_name = key.replace('-', '_')
        cli_value = getattr(args, cli_attr_name, None)
        
        # Only override if value was explicitly set (not None for optional args)
        if cli_value is not None:
            config[key] = cli_value
    
    # Ensure output directory exists
    output_path = Path(config['output'])
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    # Load data
    if config['input_data'] == "synthetic":
        msgs = create_synthetic_data()
        print(f"Loaded synthetic dataset with {len(msgs)} messages across {len(msgs['thread_id'].unique())} threads")
    elif config['input_data'] == "csv":
        if not config['csv_file']:
            parser.error("--csv-file is required when input-data=csv")
        msgs = pd.read_csv(config['csv_file'])
        # Ensure timestamp column is parsed
        msgs['timestamp'] = pd.to_datetime(msgs['timestamp'], utc=True)
        # Parse JSON columns
        for col in ['participants', 'ner']:
            if col in msgs.columns:
                msgs[col] = msgs[col].apply(json.loads)
        print(f"Loaded CSV dataset with {len(msgs)} messages across {len(msgs['thread_id'].unique())} threads")
    elif config['input_data'] == "postgres":
        if not config['as_of']:
            parser.error("--as-of is required when input-data=postgres")
        try:
            as_of_dt = datetime.fromisoformat(config['as_of'].replace('Z', '+00:00'))
        except ValueError as e:
            parser.error(f"Invalid --as-of format: {e}. Use ISO format like 2025-11-12T20:00:00Z")
        
        msgs = get_messages_from_postgres(as_of_dt, config['lookback_minutes'])
        if msgs is None or len(msgs) == 0:
            print("No messages found in postgres")
            sys.exit(1)
    
    # Initialize global state
    global last_slice_hash_by_thread
    last_slice_hash_by_thread = {}
    
    # Use as_of time if provided (for historical analysis), otherwise use current time
    if config['input_data'] == "postgres" and config['as_of']:
        now = pd.Timestamp(config['as_of'].replace('Z', '+00:00'), tz='UTC')
        print(f"Using --as-of time as reference point: {now}")
    else:
        now = pd.Timestamp.now(tz='UTC')
        print(f"Using current time as reference point: {now}")
    
    # Initialize LLM provider
    print("Initializing LLM provider...")
    llm_provider = initialize_llm_provider(config)
    if llm_provider is None:
        print("Error: Failed to initialize LLM provider")
        sys.exit(1)
    
    # Get model name for logging (extract from provider settings to ensure correctness)
    # The provider already has the correct model configured, so we'll use that
    model_name_for_logging = None
    if OpenAIProvider is not None and isinstance(llm_provider, OpenAIProvider):
        model_name_for_logging = llm_provider.settings.model  # type: ignore
    elif OllamaProvider is not None and isinstance(llm_provider, OllamaProvider):
        model_name_for_logging = llm_provider.settings.model  # type: ignore
    
    print(f"Using LLM provider: {llm_provider}")
    if model_name_for_logging:
        print(f"  Model: {model_name_for_logging}")
    
    # Run batch processing
    print("Running batch processing...")
    batch_result = run_batch(msgs, now, config)
    
    # Process intent classification for ready requests
    intent_results = []
    processed_requests = []
    max_threads_to_process = config.get('max_threads_per_batch', 15)
    for request in batch_result['ready'][:max_threads_to_process]:  # Limit for testing
        print(f"Processing thread: {request.thread_id}")
        # Don't pass model parameter - let the provider use its configured default
        # This ensures we never accidentally use the wrong model for the wrong provider
        result = call_llm_intent_classification(
            request,
            llm_provider,
            model=None  # Use provider's default model from settings
        )
        intent_results.append(result)
        processed_requests.append(request)
    
    # Generate markdown report
    print("Generating markdown report...")
    markdown_content = generate_markdown_report(batch_result, intent_results, config, processed_requests)
    
    # Write output
    with open(output_path, 'w') as f:
        f.write(markdown_content)
    
    print(f"Results written to: {output_path}")
    print(f"Processed {len(intent_results)} threads with {llm_provider.__class__.__name__}")


if __name__ == "__main__":
    main()


# Example usage:

# 1. Using all CLI arguments:
# .venv/bin/python scripts/thread_batch_processor.py \
#   --input-data postgres \
#   --as-of "2025-11-12T20:00:00Z" \
#   --lookback-minutes 240 \
#   --max-threads 10 \
#   --output .tmp/postgres_batch_results.md

# 2. Using YAML config file (recommended):
# cat > my_config.yaml << EOF
# input_data: postgres
# as_of: "2025-11-12T20:00:00Z"
# lookback_minutes: 240
# active_thread_window_minutes: 240
# thread_context_window_minutes: 240
# debounce_s: 0
# max_threads_per_batch: 10
# output: .tmp/postgres_batch_results.md
# 
# # LLM Provider Configuration
# llm_provider_type: ollama  # or 'openai'
# ollama_base_url: http://localhost:11434
# ollama_model: llama3.2:latest
# # OR for OpenAI:
# # llm_provider_type: openai
# # openai_model: gpt-4
# # openai_temperature: 0.7
# EOF
# .venv/bin/python scripts/thread_batch_processor.py -c my_config.yaml

# 3. Config file with CLI overrides (CLI args take precedence):
# .venv/bin/python scripts/thread_batch_processor.py \
#   -c my_config.yaml \
#   --max-threads 20 \
#   --llm-provider-type openai