#!/usr/bin/env python3
"""
Check for duplicate external_id values in .emlx email fixtures.

This script parses .emlx files and computes the external_id the same way
the HostAgent EmailCollector does:
1. Extract Message-ID header (if present, use as-is)
2. Otherwise, create seed from: date|subject|from
3. SHA256 hash the seed and prefix with "email:"
"""

import sys
import hashlib
from pathlib import Path
from io import BytesIO
from email import message_from_binary_file
from email.utils import parsedate_to_datetime
from collections import defaultdict
from typing import Optional, Tuple


def sha256_hex(text: str) -> str:
    """Compute SHA256 hex digest of a string."""
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def parse_emlx(path: Path) -> Optional[Tuple[str, dict]]:
    """
    Parse an .emlx file and compute its external_id.
    
    Returns:
        Tuple of (external_id, metadata) or None if parsing fails
    """
    try:
        with open(path, 'rb') as f:
            # .emlx format: first line is byte count, then XML plist, then email content
            # We'll try to read as email directly
            f.seek(0)
            first_line = f.readline()
            
            # Check if it starts with a number (byte count)
            try:
                int(first_line.strip())
                # Skip the XML plist (between <?xml and </plist>)
                content = f.read()
                # Find the start of actual email (usually after </plist>)
                if b'</plist>' in content:
                    email_start = content.find(b'</plist>') + len(b'</plist>')
                    content = content[email_start:].lstrip()
                    # Parse email from bytes
                    msg = message_from_binary_file(BytesIO(content))
                else:
                    # No plist, might be plain email
                    msg = message_from_binary_file(BytesIO(content))
            except ValueError:
                # Doesn't start with number, try parsing as plain email
                f.seek(0)
                msg = message_from_binary_file(f)
        
        # Extract Message-ID
        message_id = msg.get('Message-ID')
        if message_id:
            # Strip angle brackets if present
            message_id = message_id.strip('<>')
            external_id = f"email:{message_id}"
            return external_id, {
                'path': str(path),
                'message_id': message_id,
                'subject': msg.get('Subject', ''),
                'from': msg.get('From', ''),
                'date': msg.get('Date', '')
            }
        
        # No Message-ID, compute from date|subject|from
        seed_components = []
        
        # Date
        date_str = msg.get('Date')
        if date_str:
            try:
                date_obj = parsedate_to_datetime(date_str)
                timestamp = str(date_obj.timestamp())
                seed_components.append(timestamp)
            except:
                # If parsing fails, skip date component
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
        external_id = f"email:{sha256_hex(seed)}"
        
        return external_id, {
            'path': str(path),
            'seed': seed,
            'subject': subject,
            'from': from_addr,
            'date': date_str or ''
        }
        
    except Exception as e:
        print(f"ERROR parsing {path}: {e}", file=sys.stderr)
        return None


def main():
    """Find and check all .emlx files for duplicate external_ids."""
    fixtures_dir = Path(__file__).parent.parent / 'tests' / 'fixtures' / 'email'
    
    if not fixtures_dir.exists():
        print(f"ERROR: Fixtures directory not found: {fixtures_dir}", file=sys.stderr)
        sys.exit(1)
    
    # Find all .emlx files
    emlx_files = list(fixtures_dir.rglob('*.emlx'))
    
    if not emlx_files:
        print(f"No .emlx files found in {fixtures_dir}", file=sys.stderr)
        sys.exit(1)
    
    print(f"Found {len(emlx_files)} .emlx files in {fixtures_dir}\n")
    
    # Parse all files and group by external_id
    external_ids = defaultdict(list)
    failed = []
    
    for emlx_file in sorted(emlx_files):
        result = parse_emlx(emlx_file)
        if result:
            external_id, metadata = result
            external_ids[external_id].append(metadata)
        else:
            failed.append(emlx_file)
    
    # Report results
    print(f"Successfully parsed: {len(emlx_files) - len(failed)}")
    print(f"Failed to parse: {len(failed)}\n")
    
    if failed:
        print("Failed files:")
        for f in failed:
            print(f"  - {f}")
        print()
    
    # Check for duplicates
    duplicates = {eid: files for eid, files in external_ids.items() if len(files) > 1}
    
    if not duplicates:
        print("✅ No duplicate external_ids found!")
        
        # Also check if any emails would have the SAME external_id if Message-ID was stripped
        print("\n" + "="*80)
        print("Checking what would happen if Message-IDs were stripped/missing...")
        print("="*80 + "\n")
        
        seed_based_ids = defaultdict(list)
        
        for eid, files in external_ids.items():
            for metadata in files:
                # Recompute based on seed only
                msg_file = Path(metadata['path'])
                try:
                    with open(msg_file, 'rb') as f:
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
                    
                    seed_components = []
                    date_str = msg.get('Date')
                    if date_str:
                        try:
                            date_obj = parsedate_to_datetime(date_str)
                            timestamp = str(date_obj.timestamp())
                            seed_components.append(timestamp)
                        except:
                            pass
                    subject = msg.get('Subject', '')
                    if subject:
                        seed_components.append(subject)
                    from_addr = msg.get('From', '')
                    if from_addr:
                        seed_components.append(from_addr)
                    
                    if seed_components:
                        seed = '|'.join(seed_components)
                        seed_hash = sha256_hex(seed)
                        seed_eid = f"email:{seed_hash}"
                        seed_based_ids[seed_eid].append({
                            'path': metadata['path'],
                            'original_eid': eid,
                            'seed': seed,
                            'subject': subject,
                            'from': from_addr,
                            'date': date_str
                        })
                except:
                    pass
        
        seed_duplicates = {eid: files for eid, files in seed_based_ids.items() if len(files) > 1}
        
        if seed_duplicates:
            print(f"⚠️  Found {len(seed_duplicates)} seed-based duplicate(s) (if Message-IDs were missing):\n")
            for seed_eid, files in seed_duplicates.items():
                print(f"Seed-based External ID: {seed_eid}")
                print(f"  Would affect {len(files)} files:")
                for metadata in files:
                    print(f"    - {Path(metadata['path']).relative_to(fixtures_dir)}")
                    print(f"      Original ID: {metadata['original_eid']}")
                    print(f"      Subject: {metadata['subject']}")
                    print(f"      Seed: {metadata['seed'][:100]}...")
                print()
        else:
            print("✅ Even without Message-IDs, all seeds would be unique!")
        
        print("\nAll external_ids are unique:")
        for eid in sorted(external_ids.keys()):
            metadata = external_ids[eid][0]
            print(f"  {eid}")
            print(f"    File: {Path(metadata['path']).relative_to(fixtures_dir)}")
            if 'message_id' in metadata:
                print(f"    Message-ID: {metadata['message_id']}")
            else:
                print(f"    Seed: {metadata.get('seed', 'N/A')}")
            print()
    else:
        print(f"❌ Found {len(duplicates)} duplicate external_id(s):\n")
        for eid, files in duplicates.items():
            print(f"External ID: {eid}")
            print(f"  Appears in {len(files)} files:")
            for metadata in files:
                print(f"    - {Path(metadata['path']).relative_to(fixtures_dir)}")
                print(f"      Subject: {metadata.get('subject', 'N/A')}")
                print(f"      From: {metadata.get('from', 'N/A')}")
                print(f"      Date: {metadata.get('date', 'N/A')}")
                if 'message_id' in metadata:
                    print(f"      Message-ID: {metadata['message_id']}")
                else:
                    print(f"      Seed: {metadata.get('seed', 'N/A')}")
            print()
        
        sys.exit(1)


if __name__ == '__main__':
    main()
