#!/usr/bin/env python3
"""Analyze search test results and evaluate LLM context quality."""

import json
import re
import sys
from pathlib import Path


def extract_json_from_markdown(file_path: Path) -> list:
    """Extract JSON data from markdown file."""
    content = file_path.read_text()
    
    # Try to find JSON in code blocks - look for <details> section with JSON
    # Pattern: <details>...```json\n[...]\n```...
    details_match = re.search(r'<details>.*?```(?:json)?\n(\[.*?\])\n```', content, re.DOTALL)
    if details_match:
        try:
            return json.loads(details_match.group(1))
        except json.JSONDecodeError as e:
            print(f"Error parsing JSON from details: {e}", file=sys.stderr)
    
    # Fallback: Try to find JSON in code blocks
    json_match = re.search(r'```json\n(.*?)\n```', content, re.DOTALL)
    if not json_match:
        json_match = re.search(r'```\n(\[.*?\])\n```', content, re.DOTALL)
    
    if json_match:
        try:
            return json.loads(json_match.group(1))
        except json.JSONDecodeError as e:
            print(f"Error parsing JSON: {e}", file=sys.stderr)
            return []
    
    return []


def analyze_results(data: list) -> dict:
    """Analyze search results and return statistics."""
    stats = {
        'total_queries': len(data),
        'total_hits': 0,
        'snippet_lengths': [],
        'sender_null_count': 0,
        'sender_populated_count': 0,
        'conversation_context_present': 0,
        'conversation_summary_present': 0,
        'conversation_summary_empty_participants': 0,
        'conversation_summary_populated': 0,
        'multi_chunk_messages': 0,
        'truncated_snippets': 0,
        'long_snippets': 0,
        'context_sizes': [],
        'context_with_all_senders': 0,
        'summary_message_counts': [],
        'summary_participant_counts': [],
    }
    
    examples = {
        'sender_null': [],
        'empty_participants': [],
        'truncated': [],
        'long_snippets': [],
    }
    
    for query_result in data:
        if not isinstance(query_result, dict):
            continue
            
        result_data = query_result.get('result')
        if result_data is None or not isinstance(result_data, dict):
            continue
            
        data_obj = result_data.get('data')
        if data_obj is None or not isinstance(data_obj, dict):
            continue
            
        hits = data_obj.get('hits', [])
        stats['total_hits'] += len(hits)
        
        for hit in hits:
            if not isinstance(hit, dict):
                continue
                
            snippet = hit.get('snippet', '')
            snippet_len = len(snippet)
            stats['snippet_lengths'].append(snippet_len)
            
            # Track long snippets (potential multi-chunk success)
            if snippet_len > 1000:
                stats['long_snippets'] += 1
                if len(examples['long_snippets']) < 3:
                    examples['long_snippets'].append({
                        'query': query_result.get('query', 'N/A'),
                        'length': snippet_len,
                        'chunk_ordinal': hit.get('metadata', {}).get('chunk_ordinal'),
                        'snippet_end': snippet[-100:] if snippet_len > 100 else snippet,
                    })
            
            # Check for truncation (ends without punctuation and > 100 chars)
            if snippet_len > 100 and snippet[-1] not in '.!?…' and not snippet.endswith('...'):
                # Might be truncated if it doesn't end with sentence punctuation
                stats['truncated_snippets'] += 1
                if len(examples['truncated']) < 5:
                    examples['truncated'].append({
                        'query': query_result.get('query', 'N/A'),
                        'length': snippet_len,
                        'snippet_end': snippet[-80:],
                    })
            
            metadata = hit.get('metadata', {})
            if not isinstance(metadata, dict):
                continue
            
            # Check sender resolution
            message_meta = metadata.get('message', {})
            if isinstance(message_meta, dict):
                sender = message_meta.get('sender')
                if sender is None:
                    stats['sender_null_count'] += 1
                    if len(examples['sender_null']) < 3:
                        examples['sender_null'].append({
                            'query': query_result.get('query', 'N/A'),
                            'snippet': snippet[:100],
                            'direction': message_meta.get('direction'),
                            'thread_participants_count': len(metadata.get('thread_participants', [])),
                        })
                else:
                    stats['sender_populated_count'] += 1
            
            # Check conversation context
            conv_context = metadata.get('conversation_context', [])
            if conv_context:
                stats['conversation_context_present'] += 1
                stats['context_sizes'].append(len(conv_context))
                # Check if all context messages have sender
                if all(isinstance(msg, dict) and msg.get('sender') for msg in conv_context):
                    stats['context_with_all_senders'] += 1
            
            # Check conversation summary
            conv_summary = metadata.get('conversation_summary', {})
            if conv_summary:
                stats['conversation_summary_present'] += 1
                participants = conv_summary.get('participants', [])
                stats['summary_participant_counts'].append(len(participants))
                stats['summary_message_counts'].append(conv_summary.get('message_count', 0))
                
                if len(participants) == 0 or (len(participants) == 1 and participants[0].get('is_self')):
                    stats['conversation_summary_empty_participants'] += 1
                    if len(examples['empty_participants']) < 3:
                        examples['empty_participants'].append({
                            'query': query_result.get('query', 'N/A'),
                            'message_count': conv_summary.get('message_count', 0),
                            'participants': participants,
                            'thread_participants_count': len(metadata.get('thread_participants', [])),
                        })
                else:
                    stats['conversation_summary_populated'] += 1
            
            # Check for multi-chunk
            if metadata.get('chunk_ordinal') is not None:
                stats['multi_chunk_messages'] += 1
    
    return stats, examples


def print_report(stats: dict, examples: dict):
    """Print analysis report."""
    print("=" * 70)
    print("SEARCH TEST RESULTS EVALUATION")
    print("=" * 70)
    
    print(f"\n📊 OVERVIEW")
    print(f"  Total Queries: {stats['total_queries']}")
    print(f"  Total Hits: {stats['total_hits']}")
    
    if stats['snippet_lengths']:
        lengths = stats['snippet_lengths']
        print(f"\n📝 SNIPPET ANALYSIS")
        print(f"  Average length: {sum(lengths) / len(lengths):.1f} chars")
        print(f"  Min length: {min(lengths)} chars")
        print(f"  Max length: {max(lengths)} chars")
        print(f"  Median length: {sorted(lengths)[len(lengths)//2]} chars")
        print(f"  Long snippets (>1000 chars): {stats['long_snippets']} ({stats['long_snippets']/len(lengths)*100:.1f}%)")
        
        # Distribution
        bins = [(0, 50), (50, 100), (100, 200), (200, 500), (500, 1000), (1000, float('inf'))]
        print(f"\n  Length distribution:")
        for start, end in bins:
            if end == float('inf'):
                count = sum(1 for s in lengths if s >= start)
                label = f"{start}+"
            else:
                count = sum(1 for s in lengths if start <= s < end)
                label = f"{start}-{end}"
            pct = (count / len(lengths)) * 100 if lengths else 0
            print(f"    {label:10} chars: {count:4} ({pct:5.1f}%)")
    
    total_sender_checks = stats['sender_null_count'] + stats['sender_populated_count']
    if total_sender_checks > 0:
        print(f"\n👤 SENDER RESOLUTION")
        print(f"  ✅ Populated: {stats['sender_populated_count']} ({stats['sender_populated_count']/total_sender_checks*100:.1f}%)")
        print(f"  ❌ Null: {stats['sender_null_count']} ({stats['sender_null_count']/total_sender_checks*100:.1f}%)")
    
    if stats['conversation_context_present'] > 0:
        print(f"\n💬 CONVERSATION CONTEXT")
        print(f"  Hits with context: {stats['conversation_context_present']} ({stats['conversation_context_present']/stats['total_hits']*100:.1f}% of hits)")
        if stats['context_sizes']:
            avg_size = sum(stats['context_sizes']) / len(stats['context_sizes'])
            print(f"  Average context size: {avg_size:.1f} messages")
            print(f"  Context with all senders: {stats['context_with_all_senders']} ({stats['context_with_all_senders']/stats['conversation_context_present']*100:.1f}%)")
    
    if stats['conversation_summary_present'] > 0:
        print(f"\n📋 CONVERSATION SUMMARY")
        print(f"  Hits with summary: {stats['conversation_summary_present']} ({stats['conversation_summary_present']/stats['total_hits']*100:.1f}% of hits)")
        if stats['summary_message_counts']:
            avg_msgs = sum(stats['summary_message_counts']) / len(stats['summary_message_counts'])
            print(f"  Average message count: {avg_msgs:.1f}")
        if stats['summary_participant_counts']:
            avg_participants = sum(stats['summary_participant_counts']) / len(stats['summary_participant_counts'])
            print(f"  Average participant count: {avg_participants:.1f}")
        print(f"  ✅ With populated participants: {stats['conversation_summary_populated']}")
        print(f"  ❌ Empty/only-self participants: {stats['conversation_summary_empty_participants']}")
    
    print(f"\n🔗 MULTI-CHUNK MESSAGES")
    if stats['total_hits'] > 0:
        print(f"  Multi-chunk messages: {stats['multi_chunk_messages']} ({stats['multi_chunk_messages']/stats['total_hits']*100:.1f}% of hits)")
    else:
        print(f"  Multi-chunk messages: {stats['multi_chunk_messages']} (no hits to analyze)")
    
    # Examples
    if examples['sender_null']:
        print(f"\n⚠️  EXAMPLES: Sender is NULL")
        for i, ex in enumerate(examples['sender_null'][:3], 1):
            print(f"  {i}. Query: {ex['query']}")
            print(f"     Snippet: {ex['snippet'][:80]}...")
            print(f"     Direction: {ex['direction']}, Thread participants: {ex['thread_participants_count']}")
    
    if examples['empty_participants']:
        print(f"\n⚠️  EXAMPLES: Empty conversation_summary participants")
        for i, ex in enumerate(examples['empty_participants'][:3], 1):
            print(f"  {i}. Query: {ex['query']}")
            print(f"     Message count: {ex['message_count']}, Participants: {ex['participants']}")
            print(f"     Thread participants available: {ex['thread_participants_count']}")
    
    if examples['long_snippets']:
        print(f"\n✅ EXAMPLES: Long snippets (multi-chunk fix working?)")
        for i, ex in enumerate(examples['long_snippets'][:3], 1):
            print(f"  {i}. Query: {ex['query']}")
            print(f"     Length: {ex['length']} chars, Chunk ordinal: {ex['chunk_ordinal']}")
            print(f"     Ends with: ...{ex['snippet_end']}")
    
    print("\n" + "=" * 70)


def main():
    if len(sys.argv) < 2:
        print("Usage: analyze_search_results.py <results.md>")
        sys.exit(1)
    
    file_path = Path(sys.argv[1])
    if not file_path.exists():
        print(f"Error: File not found: {file_path}")
        sys.exit(1)
    
    data = extract_json_from_markdown(file_path)
    if not data:
        print("Error: Could not extract JSON data from markdown file")
        sys.exit(1)
    
    stats, examples = analyze_results(data)
    print_report(stats, examples)


if __name__ == "__main__":
    main()

