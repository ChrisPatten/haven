#!/usr/bin/env python3
"""
Test script to verify Ollama image format conversion fix.
"""
from __future__ import annotations

import base64
import io
import sqlite3
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow not installed. Run: pip install Pillow")
    sys.exit(1)

import requests

# Find a real iMessage image attachment
CHAT_DB = Path.home() / "Library" / "Messages" / "chat.db"

def find_test_image() -> Path | None:
    """Find a real image attachment from iMessage."""
    if not CHAT_DB.exists():
        return None
    
    conn = sqlite3.connect(f"file:{CHAT_DB}?mode=ro", uri=True)
    cursor = conn.execute("""
        SELECT filename 
        FROM attachment 
        WHERE mime_type LIKE 'image/%' 
        LIMIT 10
    """)
    
    for (filename,) in cursor.fetchall():
        if not filename:
            continue
        path = Path(str(filename)).expanduser()
        if not path.is_absolute():
            path = Path.home() / "Library" / "Messages" / "Attachments" / path
        if path.exists():
            return path
    
    return None

def test_ollama_with_conversion(image_path: Path) -> None:
    """Test sending an image to Ollama with format conversion."""
    print(f"Testing with image: {image_path}")
    print(f"  Original format: {image_path.suffix}")
    print(f"  Size: {image_path.stat().st_size:,} bytes")
    
    # Read image
    image_bytes = image_path.read_bytes()
    
    # Convert to PNG (like the collector now does)
    try:
        img = Image.open(io.BytesIO(image_bytes))
        print(f"  PIL format: {img.format}, mode: {img.mode}, size: {img.size}")
        
        if img.mode not in ('RGB', 'L'):
            print(f"  Converting {img.mode} -> RGB")
            img = img.convert('RGB')
        
        buf = io.BytesIO()
        img.save(buf, format='PNG')
        converted_bytes = buf.getvalue()
        print(f"  Converted to PNG: {len(converted_bytes):,} bytes")
        
        image_b64 = base64.b64encode(converted_bytes).decode('utf-8')
    except Exception as exc:
        print(f"  ERROR: Conversion failed: {exc}")
        return
    
    # Send to Ollama
    payload = {
        "model": "qwen2.5vl:3b",
        "prompt": "describe the image scene and contents. ignore text. short response",
        "images": [image_b64],
        "stream": False,
    }
    
    print("\nSending to Ollama...")
    try:
        resp = requests.post(
            "http://localhost:11434/api/generate",
            json=payload,
            timeout=60
        )
        print(f"  Status: {resp.status_code}")
        
        if resp.status_code == 200:
            data = resp.json()
            caption = data.get("response", "")
            print(f"  ✓ SUCCESS!")
            print(f"  Caption: {caption}")
        else:
            print(f"  ✗ FAILED: {resp.text}")
    except requests.Timeout:
        print("  ✗ TIMEOUT (>60s)")
    except Exception as exc:
        print(f"  ✗ ERROR: {exc}")

def main() -> int:
    if len(sys.argv) > 1:
        test_path = Path(sys.argv[1])
        if not test_path.exists():
            print(f"ERROR: File not found: {test_path}")
            return 1
    else:
        print("Finding a test image from iMessage attachments...")
        test_path = find_test_image()
        if not test_path:
            print("ERROR: No image attachments found in iMessage")
            print("Usage: python test_ollama_conversion.py /path/to/image.jpg")
            return 1
    
    test_ollama_with_conversion(test_path)
    return 0

if __name__ == "__main__":
    sys.exit(main())
