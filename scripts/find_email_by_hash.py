#!/usr/bin/env python3
"""
Find which email fixture corresponds to a specific external_id hash.
"""

import sys
import hashlib
from pathlib import Path
from io import BytesIO
from email import message_from_binary_file
from email.utils import parsedate_to_datetime


def sha256_hex(text: str) -> str:
    """Compute SHA256 hex digest of a string."""
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def parse_emlx(path: Path) -> tuple:
    """Parse an .emlx file and return its external_id and metadata."""
    try:
        with open(path, 'rb') as f:
            f.seek(0)
            first_line = f.readline()
            
            try:
                int(first_line.strip())
                content = f.read()
                if b'</plist>' in content:
                    email_start = content.find(b'</plist>') + len(b'</plist>')
                    content = content[email_start:].lstrip()
                    msg = message_from_binary_file(BytesIO(content))
                else:
                    msg = message_from_binary_file(BytesIO(content))
            except ValueError:
                f.seek(0)
                msg = message_from_binary_file(f)
        
        # Extract Message-ID
        message_id = msg.get('Message-ID')
        if message_id:
            message_id = message_id.strip('<>')
            external_id = f"email:{message_id}"
            return external_id, {
                'path': str(path),
                'has_message_id': True,
                'message_id': message_id,
                'subject': msg.get('Subject', ''),
                'from': msg.get('From', ''),
                'date': msg.get('Date', ''),
                'to': msg.get('To', ''),
            }
        
        # No Message-ID, compute from date|subject|from
        seed_components = []
        
        # Date
        date_str = msg.get('Date')
        timestamp_str = None
        if date_str:
            try:
                date_obj = parsedate_to_datetime(date_str)
                timestamp_str = str(date_obj.timestamp())
                seed_components.append(timestamp_str)
            except:
                pass
        
        # Subject
        subject = msg.get('Subject', '')
        if subject:
            seed_components.append(subject)
        
        # From
        from_addr = msg.get('From', '')
        if from_addr:
            seed_components.append(from_addr)
        
        seed = '|'.join(seed_components)
        hash_value = sha256_hex(seed)
        external_id = f"email:{hash_value}"
        
        return external_id, {
            'path': str(path),
            'has_message_id': False,
            'seed': seed,
            'seed_components': {
                'timestamp': timestamp_str,
                'subject': subject,
                'from': from_addr,
            },
            'hash': hash_value,
            'subject': subject,
            'from': from_addr,
            'date': date_str or '',
            'to': msg.get('To', ''),
        }
        
    except Exception as e:
        print(f"ERROR parsing {path}: {e}", file=sys.stderr)
        return None, None


def main():
    if len(sys.argv) < 2:
        print("Usage: python scripts/find_email_by_hash.py <hash_or_external_id>")
        print("\nExample:")
        print("  python scripts/find_email_by_hash.py 7e7a9291f2d47d5c82c02628f32adc7d7f252257174e98f65071c0800ed698f2")
        print("  python scripts/find_email_by_hash.py email:7e7a9291f2d47d5c82c02628f32adc7d7f252257174e98f65071c0800ed698f2")
        sys.exit(1)
    
    target = sys.argv[1]
    
    # Normalize input
    if target.startswith('email:'):
        search_hash = target[6:]  # Remove 'email:' prefix
        search_external_id = target
    else:
        search_hash = target
        search_external_id = f"email:{target}"
    
    fixtures_dir = Path(__file__).parent.parent / 'tests' / 'fixtures' / 'email'
    
    if not fixtures_dir.exists():
        print(f"ERROR: Fixtures directory not found: {fixtures_dir}", file=sys.stderr)
        sys.exit(1)
    
    emlx_files = list(fixtures_dir.rglob('*.emlx'))
    
    print(f"Searching for external_id: {search_external_id}")
    print(f"In {len(emlx_files)} .emlx files...\n")
    
    found = False
    for emlx_file in sorted(emlx_files):
        external_id, metadata = parse_emlx(emlx_file)
        if not metadata:
            continue
        
        if external_id == search_external_id or metadata.get('hash') == search_hash:
            found = True
            print(f"✅ FOUND: {emlx_file.relative_to(fixtures_dir.parent)}")
            print(f"\nExternal ID: {external_id}")
            print(f"\nMetadata:")
            print(f"  Subject: {metadata['subject']}")
            print(f"  From: {metadata['from']}")
            print(f"  To: {metadata['to']}")
            print(f"  Date: {metadata['date']}")
            
            if metadata['has_message_id']:
                print(f"\n  ✓ Has Message-ID: {metadata['message_id']}")
            else:
                print(f"\n  ✗ NO Message-ID (computed from seed)")
                print(f"\n  Seed components:")
                for key, value in metadata['seed_components'].items():
                    print(f"    {key}: {value}")
                print(f"\n  Full seed: {metadata['seed']}")
                print(f"  SHA256 hash: {metadata['hash']}")
            print()
    
    if not found:
        print("❌ No matching email found.")
        print("\nShowing all emails WITHOUT Message-ID:")
        
        for emlx_file in sorted(emlx_files):
            external_id, metadata = parse_emlx(emlx_file)
            if metadata and not metadata['has_message_id']:
                print(f"\n  {emlx_file.relative_to(fixtures_dir.parent)}")
                print(f"    External ID: {external_id}")
                print(f"    Subject: {metadata['subject']}")
                print(f"    Seed: {metadata['seed']}")


if __name__ == '__main__':
    main()
