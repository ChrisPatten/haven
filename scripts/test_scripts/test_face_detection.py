#!/usr/bin/env python3
"""
Test script for face detection endpoint.

Tests the /v1/face/detect endpoint with various images.
"""

import json
import sys
import base64
from pathlib import Path
import requests

# Configuration
BASE_URL = "http://localhost:7090"
AUTH_SECRET = "change-me"

def test_face_detection(image_path: str, include_landmarks: bool = False):
    """Test face detection with an image file."""
    print(f"\n{'='*60}")
    print(f"Testing face detection: {image_path}")
    print(f"Include landmarks: {include_landmarks}")
    print('='*60)
    
    if not Path(image_path).exists():
        print(f"❌ Error: Image not found at {image_path}")
        return False
    
    # Test with image path
    print("\n1. Testing with image_path...")
    response = requests.post(
        f"{BASE_URL}/v1/face/detect",
        headers={
            "Content-Type": "application/json",
            "x-auth": AUTH_SECRET
        },
        json={
            "image_path": image_path,
            "include_landmarks": include_landmarks
        }
    )
    
    print(f"Status: {response.status_code}")
    
    if response.status_code == 200:
        data = response.json()
        print(f"✅ Success!")
        print(f"\nResponse:")
        print(json.dumps(data, indent=2))
        
        if data.get("status") == "success":
            faces = data.get("data", {}).get("faces", [])
            image_size = data.get("data", {}).get("imageSize")
            
            print(f"\n📊 Results:")
            print(f"  - Faces detected: {len(faces)}")
            if image_size:
                print(f"  - Image size: {image_size['width']}x{image_size['height']}")
            
            for i, face in enumerate(faces, 1):
                print(f"\n  Face {i}:")
                bbox = face.get("boundingBox", {})
                print(f"    - Bounding box: x={bbox.get('x', 0):.3f}, y={bbox.get('y', 0):.3f}, "
                      f"w={bbox.get('width', 0):.3f}, h={bbox.get('height', 0):.3f}")
                print(f"    - Confidence: {face.get('confidence', 0):.3f}")
                print(f"    - Quality score: {face.get('qualityScore', 0):.3f}")
                print(f"    - Face ID: {face.get('faceId', 'N/A')}")
                
                if include_landmarks and face.get("landmarks"):
                    landmarks = face["landmarks"]
                    print(f"    - Landmarks detected:")
                    for landmark_name, point in landmarks.items():
                        if point:
                            print(f"      - {landmark_name}: ({point['x']:.3f}, {point['y']:.3f})")
        return True
    else:
        print(f"❌ Error: {response.status_code}")
        print(response.text)
        return False

def test_face_detection_base64(image_path: str):
    """Test face detection with base64-encoded image data."""
    print(f"\n{'='*60}")
    print(f"Testing face detection with base64 encoding: {image_path}")
    print('='*60)
    
    if not Path(image_path).exists():
        print(f"❌ Error: Image not found at {image_path}")
        return False
    
    # Read and encode image
    with open(image_path, "rb") as f:
        image_data = base64.b64encode(f.read()).decode("utf-8")
    
    print(f"\n2. Testing with base64-encoded image_data (size: {len(image_data)} chars)...")
    response = requests.post(
        f"{BASE_URL}/v1/face/detect",
        headers={
            "Content-Type": "application/json",
            "x-auth": AUTH_SECRET
        },
        json={
            "image_data": image_data,
            "include_landmarks": False
        }
    )
    
    print(f"Status: {response.status_code}")
    
    if response.status_code == 200:
        data = response.json()
        print(f"✅ Success!")
        faces = data.get("data", {}).get("faces", [])
        print(f"  - Faces detected: {len(faces)}")
        return True
    else:
        print(f"❌ Error: {response.status_code}")
        print(response.text)
        return False

def main():
    """Main test runner."""
    if len(sys.argv) < 2:
        # Use default test image
        image_path = "/Users/chrispatten/workspace/haven/tests/fixtures/images/j_soccer.heic"
        print(f"No image path provided, using default: {image_path}")
    else:
        image_path = sys.argv[1]
    
    include_landmarks = False
    if len(sys.argv) >= 3:
        include_landmarks = sys.argv[2].lower() in ("true", "1", "yes")
    
    print("🧪 Face Detection Test Suite")
    print(f"Endpoint: {BASE_URL}/v1/face/detect")
    
    # Test 1: Image path without landmarks
    success1 = test_face_detection(image_path, include_landmarks=False)
    
    # Test 2: Image path with landmarks (if requested)
    if include_landmarks:
        success2 = test_face_detection(image_path, include_landmarks=True)
    else:
        success2 = True
    
    # Test 3: Base64 encoding
    success3 = test_face_detection_base64(image_path)
    
    # Summary
    print(f"\n{'='*60}")
    print("📝 Test Summary")
    print('='*60)
    print(f"Image path test: {'✅ PASS' if success1 else '❌ FAIL'}")
    if include_landmarks:
        print(f"Landmarks test: {'✅ PASS' if success2 else '❌ FAIL'}")
    print(f"Base64 test: {'✅ PASS' if success3 else '❌ FAIL'}")
    
    all_pass = success1 and success2 and success3
    print(f"\nOverall: {'✅ ALL TESTS PASSED' if all_pass else '❌ SOME TESTS FAILED'}")
    
    return 0 if all_pass else 1

if __name__ == "__main__":
    sys.exit(main())
