#!/usr/bin/env python3
"""
Generate a detailed report of expected external_ids from .emlx fixtures.
This can be compared against what the Swift collector actually generates.
"""

import sys
import json
import hashlib
from pathlib import Path
from io import BytesIO
from email import message_from_binary_file
from email.utils import parsedate_to_datetime


def sha256_hex(text: str) -> str:
    """Compute SHA256 hex digest of a string."""
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def parse_emlx(path: Path) -> dict:
    """Parse an .emlx file and return detailed information."""
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
        
        # Extract all relevant fields
        message_id_raw = msg.get('Message-ID', '')
        message_id = message_id_raw.strip('<>').strip() if message_id_raw else None
        
        subject = msg.get('Subject', '')
        from_addr = msg.get('From', '')
        to_addr = msg.get('To', '')
        date_str = msg.get('Date', '')
        
        # Compute timestamp
        timestamp_str = None
        if date_str:
            try:
                date_obj = parsedate_to_datetime(date_str)
                timestamp_str = str(date_obj.timestamp())
            except:
                pass
        
        # Compute external_id with Message-ID
        if message_id:
            external_id_with_msgid = f"email:{message_id}"
        else:
            external_id_with_msgid = None
        
        # Compute external_id without Message-ID (seed-based)
        seed_components = []
        if timestamp_str:
            seed_components.append(timestamp_str)
        if subject:
            seed_components.append(subject)
        if from_addr:
            seed_components.append(from_addr)
        
        if seed_components:
            seed = '|'.join(seed_components)
            seed_hash = sha256_hex(seed)
            external_id_seed_based = f"email:{seed_hash}"
        else:
            seed = None
            external_id_seed_based = None
        
        return {
            'file_path': str(path),
            'message_id_raw': message_id_raw,
            'message_id': message_id,
            'subject': subject,
            'from': from_addr,
            'to': to_addr,
            'date': date_str,
            'timestamp': timestamp_str,
            'seed': seed,
            'external_id_with_msgid': external_id_with_msgid,
            'external_id_seed_based': external_id_seed_based,
            'expected_external_id': external_id_with_msgid or external_id_seed_based,
        }
        
    except Exception as e:
        return {
            'file_path': str(path),
            'error': str(e),
        }


def main():
    fixtures_dir = Path(__file__).parent.parent / 'tests' / 'fixtures' / 'email'
    
    if not fixtures_dir.exists():
        print(f"ERROR: Fixtures directory not found: {fixtures_dir}", file=sys.stderr)
        sys.exit(1)
    
    emlx_files = sorted(fixtures_dir.rglob('*.emlx'))
    
    print(f"# Email Fixture External ID Report")
    print(f"\nTotal .emlx files: {len(emlx_files)}\n")
    print("=" * 100)
    
    results = []
    for emlx_file in emlx_files:
        result = parse_emlx(emlx_file)
        results.append(result)
        
        rel_path = emlx_file.relative_to(fixtures_dir)
        print(f"\n## {rel_path}")
        
        if 'error' in result:
            print(f"   ❌ ERROR: {result['error']}")
            continue
        
        print(f"   Expected External ID: {result['expected_external_id']}")
        
        if result['message_id']:
            print(f"   ✓ Has Message-ID: {result['message_id']}")
        else:
            print(f"   ✗ NO Message-ID - using seed-based")
            print(f"   Seed: {result['seed']}")
            print(f"   Hash: {result['external_id_seed_based'][6:]}")  # Skip 'email:' prefix
        
        print(f"   Subject: {result['subject']}")
        print(f"   From: {result['from']}")
        print(f"   Date: {result['date']}")
    
    # Summary
    print("\n" + "=" * 100)
    print("\n# Summary\n")
    
    with_msgid = [r for r in results if 'error' not in r and r['message_id']]
    without_msgid = [r for r in results if 'error' not in r and not r['message_id']]
    errors = [r for r in results if 'error' in r]
    
    print(f"With Message-ID: {len(with_msgid)}")
    print(f"Without Message-ID (seed-based): {len(without_msgid)}")
    print(f"Parse errors: {len(errors)}")
    
    # Check for duplicates in expected external_ids
    from collections import Counter
    external_ids = [r['expected_external_id'] for r in results if 'expected_external_id' in r]
    counts = Counter(external_ids)
    duplicates = {eid: count for eid, count in counts.items() if count > 1}
    
    if duplicates:
        print(f"\n⚠️  DUPLICATES FOUND: {len(duplicates)} external_id(s) appear multiple times!")
        for eid, count in duplicates.items():
            print(f"\n  {eid} appears {count} times in:")
            for r in results:
                if r.get('expected_external_id') == eid:
                    print(f"    - {Path(r['file_path']).relative_to(fixtures_dir)}")
    else:
        print(f"\n✅ All expected external_ids are unique!")
    
    # Save JSON report
    output_file = Path('.tmp/email_external_ids.json')
    output_file.parent.mkdir(exist_ok=True)
    with open(output_file, 'w') as f:
        json.dump(results, f, indent=2)
    print(f"\n📄 Detailed JSON report saved to: {output_file}")


if __name__ == '__main__':
    main()
