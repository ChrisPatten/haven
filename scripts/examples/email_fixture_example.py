#!/usr/bin/env python3
"""
Example script demonstrating email fixture generation and usage.

This script shows how to:
1. Generate email fixtures programmatically
2. Use fixtures in tests
3. Query the Envelope Index database
4. Work with the catalog
"""

import json
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Add project root to path
PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from scripts import generate_email_fixtures as gen


def example_generate_fixtures():
    """Example: Generate a small fixture set"""
    print("=== Example 1: Generate Fixtures ===\n")
    
    output_dir = Path.home() / ".haven" / "example_fixtures"
    output_dir.mkdir(parents=True, exist_ok=True)
    
    messages_dir = output_dir / "Messages"
    messages_dir.mkdir(exist_ok=True)
    
    # Generate templates
    templates = gen.generate_templates(count=10, noise_ratio=0.2)
    
    print(f"Generated {len(templates)} email templates:")
    for i, template in enumerate(templates):
        noise = " (NOISE)" if template.is_noise else ""
        print(f"  {i+1}. [{template.intent}]{noise} {template.subject}")
    
    # Write .emlx files
    metadata_list = []
    start_date = datetime.now(timezone.utc) - timedelta(days=30)
    
    for i, template in enumerate(templates):
        email_date = start_date + timedelta(days=i * 3)
        metadata = gen.write_emlx_file(messages_dir, i, template, email_date)
        metadata_list.append(metadata)
    
    # Create database and catalog
    db_path = output_dir / "Envelope Index"
    gen.create_envelope_index_db(db_path, metadata_list)
    gen.create_catalog_json(output_dir, metadata_list)
    gen.create_readme(output_dir, metadata_list)
    
    print(f"\n✓ Fixtures generated in: {output_dir}")
    print(f"  - .emlx files: {len(list(messages_dir.glob('*.emlx')))}")
    print(f"  - Database: {db_path.name}")
    print(f"  - Catalog: catalog.json")
    
    return output_dir


def example_query_envelope_index(fixture_dir: Path):
    """Example: Query the Envelope Index database"""
    print("\n=== Example 2: Query Envelope Index ===\n")
    
    db_path = fixture_dir / "Envelope Index"
    
    conn = sqlite3.connect(str(db_path))
    cursor = conn.cursor()
    
    # Get total messages
    cursor.execute("SELECT COUNT(*) FROM messages")
    total = cursor.fetchone()[0]
    print(f"Total messages: {total}")
    
    # Get messages by mailbox
    cursor.execute("""
        SELECT mailbox, COUNT(*) as count 
        FROM messages 
        GROUP BY mailbox 
        ORDER BY count DESC
    """)
    
    print("\nMessages by mailbox:")
    for mailbox, count in cursor.fetchall():
        print(f"  {mailbox}: {count}")
    
    # Get junk messages
    cursor.execute("""
        SELECT subject, sender 
        FROM messages 
        WHERE junk = 1
        LIMIT 5
    """)
    
    print("\nJunk/promotional messages:")
    for subject, sender in cursor.fetchall():
        print(f"  [{sender}] {subject}")
    
    # Get recent messages
    cursor.execute("""
        SELECT subject, datetime(date_received, 'unixepoch') as date
        FROM messages 
        ORDER BY date_received DESC
        LIMIT 5
    """)
    
    print("\nRecent messages:")
    for subject, date in cursor.fetchall():
        print(f"  {date}: {subject}")
    
    conn.close()


def example_read_catalog(fixture_dir: Path):
    """Example: Read and analyze the catalog"""
    print("\n=== Example 3: Analyze Catalog ===\n")
    
    catalog_path = fixture_dir / "catalog.json"
    catalog = json.loads(catalog_path.read_text())
    
    print(f"Catalog generated: {catalog['generated_at']}")
    print(f"Total emails: {catalog['total_emails']}")
    print(f"Signal emails: {catalog['stats']['signal_emails']}")
    print(f"Noise emails: {catalog['stats']['noise_emails']}")
    
    print("\nEmails by intent:")
    for intent, count in sorted(catalog['stats']['intents'].items()):
        percentage = (count / catalog['total_emails']) * 100
        print(f"  {intent:20s}: {count:3d} ({percentage:5.1f}%)")
    
    # Find emails with attachments
    emails_with_attachments = [
        email for email in catalog['emails']
        if email.get('has_attachment', False)
    ]
    
    print(f"\nEmails with attachments: {len(emails_with_attachments)}")
    for email in emails_with_attachments[:3]:
        print(f"  - {email['subject']}")


def example_parse_emlx(fixture_dir: Path):
    """Example: Parse an .emlx file"""
    print("\n=== Example 4: Parse .emlx File ===\n")
    
    messages_dir = fixture_dir / "Messages"
    emlx_files = sorted(messages_dir.glob("*.emlx"))
    
    if not emlx_files:
        print("No .emlx files found")
        return
    
    # Parse first file
    emlx_path = emlx_files[0]
    content = emlx_path.read_text()
    lines = content.split('\n')
    
    # First line is byte count
    byte_count = int(lines[0])
    message = '\n'.join(lines[1:])
    
    print(f"File: {emlx_path.name}")
    print(f"Size: {byte_count} bytes")
    
    # Parse headers
    headers = {}
    body_start = 0
    for i, line in enumerate(lines[1:]):
        if not line.strip():
            body_start = i + 2
            break
        if ':' in line:
            key, value = line.split(':', 1)
            headers[key] = value.strip()
    
    print(f"\nHeaders:")
    for key in ['From', 'To', 'Subject', 'Date', 'Message-ID']:
        if key in headers:
            print(f"  {key}: {headers[key]}")
    
    # Show first few lines of body
    body_lines = lines[body_start:body_start + 5]
    print(f"\nBody preview:")
    for line in body_lines:
        if line.strip():
            print(f"  {line[:80]}")


def example_simulate_collector_run(fixture_dir: Path):
    """Example: Simulate what a collector would do"""
    print("\n=== Example 5: Simulate Collector Run ===\n")
    
    messages_dir = fixture_dir / "Messages"
    emlx_files = sorted(messages_dir.glob("*.emlx"))
    
    print(f"Scanning {messages_dir}...")
    print(f"Found {len(emlx_files)} .emlx files\n")
    
    # Simulate processing
    processed = 0
    errors = 0
    intents = {}
    
    for emlx_path in emlx_files:
        try:
            # Parse basic info
            content = emlx_path.read_text()
            lines = content.split('\n')
            
            # Extract subject
            subject = None
            for line in lines[1:]:
                if line.startswith('Subject:'):
                    subject = line.split(':', 1)[1].strip()
                    break
            
            # Simulate intent classification (simplified)
            intent = "unknown"
            if subject:
                subject_lower = subject.lower()
                if any(word in subject_lower for word in ['order', 'receipt', 'confirmation']):
                    intent = 'receipt'
                elif any(word in subject_lower for word in ['bill', 'statement', 'invoice']):
                    intent = 'bill'
                elif 'appointment' in subject_lower:
                    intent = 'appointment'
                elif any(word in subject_lower for word in ['shipped', 'tracking', 'delivery']):
                    intent = 'notification'
                elif any(word in subject_lower for word in ['verify', 'confirm', 'reset']):
                    intent = 'action_request'
                elif any(word in subject_lower for word in ['sale', 'newsletter', 'offer']):
                    intent = 'promotional'
            
            intents[intent] = intents.get(intent, 0) + 1
            processed += 1
            
        except Exception as e:
            print(f"  Error processing {emlx_path.name}: {e}")
            errors += 1
    
    print(f"Processing complete:")
    print(f"  Processed: {processed}")
    print(f"  Errors: {errors}")
    
    print(f"\nIntent distribution:")
    for intent, count in sorted(intents.items()):
        print(f"  {intent:20s}: {count}")
    
    print(f"\n✓ Collector simulation complete")


def main():
    """Run all examples"""
    print("Haven Email Fixture Generator - Usage Examples")
    print("=" * 60)
    
    # Generate fixtures
    fixture_dir = example_generate_fixtures()
    
    # Query database
    example_query_envelope_index(fixture_dir)
    
    # Analyze catalog
    example_read_catalog(fixture_dir)
    
    # Parse .emlx
    example_parse_emlx(fixture_dir)
    
    # Simulate collector
    example_simulate_collector_run(fixture_dir)
    
    print("\n" + "=" * 60)
    print("Examples complete!")
    print(f"\nFixtures saved to: {fixture_dir}")
    print("\nTo use with HostAgent:")
    print(f"  curl -X POST http://localhost:7090/v1/collectors/email_local:run \\")
    print(f"    -H 'Content-Type: application/json' \\")
    print(f"    -H 'x-auth: change-me' \\")
    print(f"    -d '{{\"mode\":\"simulate\",\"simulate_path\":\"{fixture_dir / 'Messages'}\",\"limit\":10}}'")


if __name__ == "__main__":
    main()
