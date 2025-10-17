#!/usr/bin/env python3
"""
Test script for Enhanced OCR (Unit 3.1) functionality.

This script tests the new features:
- Recognition level (fast/accurate)
- Layout extraction with regions
- Language detection
- Bounding box coordinates
"""

import json
import os
import sys
import requests
from pathlib import Path

def test_ocr_endpoint(image_path: str, recognition_level: str = "fast", include_layout: bool = True):
    """Test the OCR endpoint with an image."""
    
    if not Path(image_path).exists():
        print(f"❌ Error: Image file not found: {image_path}")
        return False
    
    url = "http://localhost:7090/v1/ocr"
    
    # Get auth token from environment or use default
    auth_token = os.environ.get("HOSTAGENT_AUTH_TOKEN", "change-me")
    
    headers = {
        "x-auth": auth_token,
        "Content-Type": "application/json"
    }
    
    payload = {
        "image_path": str(Path(image_path).absolute()),
        "recognition_level": recognition_level,
        "include_layout": include_layout
    }
    
    print(f"\n{'='*60}")
    print(f"Testing OCR with:")
    print(f"  Image: {image_path}")
    print(f"  Recognition Level: {recognition_level}")
    print(f"  Include Layout: {include_layout}")
    print(f"  Auth: {'✓' if auth_token else '✗'}")
    print(f"{'='*60}\n")
    
    try:
        response = requests.post(url, json=payload, headers=headers, timeout=10)
        
        if response.status_code == 401:
            print(f"❌ Authentication failed (401 Unauthorized)")
            print(f"   Make sure HOSTAGENT_AUTH_TOKEN matches the config")
            print(f"   Current token: {auth_token}")
            print(f"   Set with: export HOSTAGENT_AUTH_TOKEN=your-token")
            return False
        
        if response.status_code != 200:
            print(f"❌ Request failed with status {response.status_code}")
            print(f"Response: {response.text}")
            return False
        
        result = response.json()
        
        # Display results
        print("✅ OCR Successful!\n")
        
        print(f"📝 Extracted Text ({len(result.get('ocr_text', ''))} chars):")
        print("-" * 60)
        print(result.get('ocr_text', '')[:500])  # Show first 500 chars
        if len(result.get('ocr_text', '')) > 500:
            print("... (truncated)")
        print()
        
        if 'detected_languages' in result and result['detected_languages']:
            print(f"🌐 Detected Languages: {', '.join(result['detected_languages'])}")
        
        if 'recognition_level' in result:
            print(f"🎯 Recognition Level: {result['recognition_level']}")
        
        print(f"\n📦 Bounding Boxes: {len(result.get('ocr_boxes', []))} boxes")
        
        if include_layout and 'regions' in result:
            regions = result.get('regions', [])
            print(f"📍 Layout Regions: {len(regions)} regions")
            
            if regions:
                print("\nSample Regions (first 3):")
                for i, region in enumerate(regions[:3]):
                    print(f"\n  Region {i+1}:")
                    print(f"    Text: {region['text'][:50]}...")
                    print(f"    Confidence: {region['confidence']:.3f}")
                    bbox = region['bounding_box']
                    print(f"    BBox: x={bbox['x']:.3f}, y={bbox['y']:.3f}, w={bbox['width']:.3f}, h={bbox['height']:.3f}")
                    if 'detected_language' in region and region['detected_language']:
                        print(f"    Language: {region['detected_language']}")
        
        if 'timings_ms' in result:
            timings = result['timings_ms']
            print(f"\n⏱️  Timings:")
            for key, value in timings.items():
                print(f"    {key}: {value}ms")
        
        print(f"\n{'='*60}")
        print("✅ Test completed successfully!")
        print(f"{'='*60}\n")
        
        return True
        
    except requests.exceptions.ConnectionError:
        print("❌ Error: Could not connect to hostagent at localhost:7090")
        print("   Make sure hostagent is running: cd hostagent && swift run")
        return False
    except Exception as e:
        print(f"❌ Error: {e}")
        return False

def main():
    if len(sys.argv) < 2:
        print("Usage: python test_enhanced_ocr.py <image_path> [recognition_level] [include_layout]")
        print("\nExamples:")
        print("  python test_enhanced_ocr.py screenshot.png")
        print("  python test_enhanced_ocr.py screenshot.png accurate true")
        print("  python test_enhanced_ocr.py screenshot.png fast false")
        sys.exit(1)
    
    image_path = sys.argv[1]
    recognition_level = sys.argv[2] if len(sys.argv) > 2 else "fast"
    include_layout = sys.argv[3].lower() == "true" if len(sys.argv) > 3 else True
    
    success = test_ocr_endpoint(image_path, recognition_level, include_layout)
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
