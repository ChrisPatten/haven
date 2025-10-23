#!/usr/bin/env python3
"""
Test script for Haven Host Agent entity extraction endpoint.

This script tests the /v1/entities endpoint with various text inputs
and validates the entity extraction functionality.

Usage:
    python test_entity_extraction.py
    python test_entity_extraction.py --url http://localhost:7090 --auth changeme
"""

import sys
import json
import requests
import argparse
import os
from typing import Dict, Any, Optional, List
from dataclasses import dataclass

HOSTAGENT_URL = "http://localhost:7090"
AUTH_TOKEN = "changeme"

@dataclass
class TestResult:
    """Store test results for summary reporting."""
    name: str
    passed: bool
    error_message: Optional[str] = None
    entities_found: int = 0
    expected_entities: Optional[List[str]] = None

def test_entity_extraction(
    text: str, 
    enabled_types: Optional[list] = None, 
    min_confidence: Optional[float] = None,
    expected_entities: Optional[List[str]] = None,
    test_name: str = "Entity Extraction Test"
) -> TestResult:
    """
    Test entity extraction on provided text.
    
    Args:
        text: Text to extract entities from
        enabled_types: Optional list of entity types to filter
        min_confidence: Optional minimum confidence threshold
        expected_entities: Optional list of expected entity texts for validation
        test_name: Name of the test for reporting
    
    Returns:
        TestResult with pass/fail status and details
    """
    
    url = f"{HOSTAGENT_URL}/v1/entities"
    headers = {
        "Content-Type": "application/json",
        "x-auth": AUTH_TOKEN
    }
    
    payload = {"text": text}
    if enabled_types:
        payload["enabled_types"] = enabled_types
    if min_confidence is not None:
        payload["min_confidence"] = min_confidence
    
    print(f"\n{'='*70}")
    print(f"🧪 Test: {test_name}")
    print(f"{'='*70}")
    print(f"📝 Text: {text[:100]}..." if len(text) > 100 else f"📝 Text: {text}")
    if enabled_types:
        print(f"🔍 Entity types filter: {', '.join(enabled_types)}")
    if min_confidence is not None:
        print(f"📊 Min confidence: {min_confidence}")
    if expected_entities:
        print(f"✓ Expected entities: {', '.join(expected_entities)}")
    print(f"{'-'*70}")
    
    try:
        response = requests.post(url, headers=headers, json=payload, timeout=10)
        response.raise_for_status()
        
        result = response.json()
        
        entities = result.get('entities', [])
        total_entities = result.get('total_entities', 0)
        processing_time = result.get('timings_ms', {}).get('total', 0)
        
        # Print results
        print(f"\n📊 Results:")
        print(f"   • Total entities: {total_entities}")
        print(f"   • Processing time: {processing_time}ms")
        
        if entities:
            print(f"\n🎯 Entities found:")
            for i, entity in enumerate(entities, 1):
                entity_type = entity['type']
                entity_text = entity['text']
                entity_range = entity['range']
                entity_conf = entity['confidence']
                
                # Use emojis for entity types
                emoji = {
                    'person': '👤',
                    'organization': '🏢',
                    'place': '📍'
                }.get(entity_type, '🔖')
                
                print(f"   {i}. {emoji} [{entity_type.upper()}] \"{entity_text}\"")
                print(f"      Range: {entity_range}, Confidence: {entity_conf:.2f}")
        else:
            print("   ⚠️  No entities found.")
        
        # Validation
        passed = True
        error_msg = None
        
        if expected_entities:
            found_texts = [e['text'] for e in entities]
            missing = [e for e in expected_entities if e not in found_texts]
            extra = [e for e in found_texts if e not in expected_entities]
            
            if missing:
                passed = False
                error_msg = f"Missing expected entities: {', '.join(missing)}"
                print(f"\n❌ Validation failed: {error_msg}")
            elif extra:
                print(f"\n⚠️  Found unexpected entities: {', '.join(extra)}")
            else:
                print(f"\n✅ Validation passed: All expected entities found!")
        else:
            print(f"\n✅ Test completed successfully!")
        
        return TestResult(
            name=test_name,
            passed=passed,
            entities_found=total_entities,
            expected_entities=expected_entities,
            error_message=error_msg
        )
        
    except requests.exceptions.RequestException as e:
        print(f"\n❌ Request failed: {e}")
        if hasattr(e, 'response') and e.response is not None:
            print(f"   Response status: {e.response.status_code}")
            print(f"   Response body: {e.response.text}")
        return TestResult(
            name=test_name,
            passed=False,
            error_message=str(e)
        )
    except Exception as e:
        print(f"\n❌ Error: {e}")
        return TestResult(
            name=test_name,
            passed=False,
            error_message=str(e)
        )

def test_ocr_with_entities(image_path: str = None) -> Optional[TestResult]:
    """Test OCR endpoint with entity extraction enabled."""
    print(f"\n{'='*70}")
    print(f"🧪 Testing OCR + Entity Extraction Integration")
    print(f"{'='*70}")
    
    if not image_path:
        print(f"ℹ️  Note: No image path provided, skipping OCR integration test")
        print(f"    Use --image <path> to test OCR with entity extraction")
        print(f"{'='*70}")
        return None
    
    # Convert relative path to absolute path
    abs_image_path = os.path.abspath(image_path)
    
    if not os.path.exists(abs_image_path):
        print(f"❌ Error: Image file not found: {abs_image_path}")
        print(f"{'='*70}")
        return TestResult(
            name="OCR + Entity Extraction Integration",
            passed=False,
            error_message=f"Image file not found: {abs_image_path}"
        )
    
    url = f"{HOSTAGENT_URL}/v1/ocr"
    headers = {
        "Content-Type": "application/json",
        "x-auth": AUTH_TOKEN
    }
    
    payload = {
        "image_path": abs_image_path,
        "extract_entities": True
    }
    
    print(f"📸 Image: {image_path}")
    print(f"📂 Absolute path: {abs_image_path}")
    print(f"🔍 Entity extraction: Enabled")
    print(f"{'-'*70}")
    
    try:
        response = requests.post(url, headers=headers, json=payload, timeout=30)
        response.raise_for_status()
        
        result = response.json()
        
        ocr_text = result.get('ocr_text', '')
        entities = result.get('entities', [])
        
        print(f"\n📊 Results:")
        print(f"   • OCR text length: {len(ocr_text)} characters")
        print(f"   • Text preview: {ocr_text[:100]}..." if len(ocr_text) > 100 else f"   • Text: {ocr_text}")
        print(f"   • Entities extracted: {len(entities)}")
        
        if entities:
            print(f"\n🎯 Entities found in image:")
            for i, entity in enumerate(entities, 1):
                entity_type = entity['type']
                entity_text = entity['text']
                
                emoji = {
                    'person': '👤',
                    'organization': '🏢',
                    'place': '📍'
                }.get(entity_type, '🔖')
                
                print(f"   {i}. {emoji} [{entity_type.upper()}] \"{entity_text}\"")
        else:
            print("   ℹ️  No entities found in OCR text")
        
        print(f"\n✅ OCR + Entity extraction test completed successfully!")
        
        return TestResult(
            name="OCR + Entity Extraction Integration",
            passed=True,
            entities_found=len(entities)
        )
        
    except requests.exceptions.RequestException as e:
        print(f"\n❌ Request failed: {e}")
        if hasattr(e, 'response') and e.response is not None:
            print(f"   Response status: {e.response.status_code}")
            print(f"   Response body: {e.response.text[:200]}")
        return TestResult(
            name="OCR + Entity Extraction Integration",
            passed=False,
            error_message=str(e)
        )
    except Exception as e:
        print(f"\n❌ Error: {e}")
        return TestResult(
            name="OCR + Entity Extraction Integration",
            passed=False,
            error_message=str(e)
        )

def print_summary(results: List[TestResult]):
    """Print test summary."""
    print(f"\n{'='*70}")
    print(f"📋 TEST SUMMARY")
    print(f"{'='*70}")
    
    total = len(results)
    passed = sum(1 for r in results if r.passed)
    failed = total - passed
    
    print(f"\n📊 Overall Results:")
    print(f"   • Total tests: {total}")
    print(f"   • Passed: {passed} ✅")
    print(f"   • Failed: {failed} ❌")
    print(f"   • Success rate: {(passed/total*100):.1f}%")
    
    if failed > 0:
        print(f"\n❌ Failed Tests:")
        for result in results:
            if not result.passed:
                print(f"   • {result.name}")
                if result.error_message:
                    print(f"     Error: {result.error_message}")
    
    print(f"\n{'='*70}")
    
    return passed == total

def main():
    """Run entity extraction tests."""
    
    parser = argparse.ArgumentParser(description='Test Haven Host Agent entity extraction')
    parser.add_argument('--url', default='http://localhost:7090', help='Host agent URL')
    parser.add_argument('--auth', default='changeme', help='Auth token')
    parser.add_argument('--image', help='Path to image file for OCR + entity extraction test')
    args = parser.parse_args()
    
    global HOSTAGENT_URL, AUTH_TOKEN
    HOSTAGENT_URL = args.url
    AUTH_TOKEN = args.auth
    
    print("\n" + "🏠" * 35)
    print("🏠  Haven Host Agent - Entity Extraction Test Suite  🏠")
    print("🏠" * 35)
    print(f"\n🔗 Testing endpoint: {HOSTAGENT_URL}/v1/entities")
    print(f"🔑 Auth token: {'*' * len(AUTH_TOKEN)}")
    
    results = []
    
    # Test 1: Simple text with person and place
    results.append(test_entity_extraction(
        text="Meet John Smith at Apple Park on Monday at 3pm",
        expected_entities=["John Smith", "Apple Park"],
        test_name="Test 1: Person and Place"
    ))
    
    # Test 2: Business communication with multiple entity types
    results.append(test_entity_extraction(
        text="Dear Ms. Johnson, Please send the documents to Microsoft headquarters in Redmond, Washington by Friday.",
        expected_entities=["Microsoft", "Redmond", "Washington"],
        test_name="Test 2: Business Communication"
    ))
    
    # Test 3: Filter by entity type (only person)
    results.append(test_entity_extraction(
        text="Steve Jobs founded Apple Computer with Steve Wozniak in Cupertino.",
        enabled_types=["person"],
        expected_entities=["Steve Jobs", "Steve Wozniak"],
        test_name="Test 3: Person Filter"
    ))
    
    # Test 4: Multiple people and organizations
    results.append(test_entity_extraction(
        text="The CEO of Amazon, Jeff Bezos, met with Tim Cook from Apple and Satya Nadella from Microsoft.",
        test_name="Test 4: Multiple Entities"
    ))
    
    # Test 5: Places and geographic locations
    results.append(test_entity_extraction(
        text="The event will be held at the Golden Gate Bridge in San Francisco, California.",
        enabled_types=["place"],
        test_name="Test 5: Geographic Locations"
    ))
    
    # Test 6: Organizations filter
    results.append(test_entity_extraction(
        text="Google, Facebook, Amazon, and Netflix are major tech companies in Silicon Valley.",
        enabled_types=["organization"],
        test_name="Test 6: Organization Filter"
    ))
    
    # Test 7: Text with no entities (edge case)
    results.append(test_entity_extraction(
        text="The quick brown fox jumps over the lazy dog.",
        expected_entities=[],
        test_name="Test 7: No Entities (Edge Case)"
    ))
    
    # Test 8: International names
    results.append(test_entity_extraction(
        text="Juan García works at Google España in Madrid, Spain.",
        test_name="Test 8: International Names"
    ))
    
    # Test 9: Email/Professional context
    results.append(test_entity_extraction(
        text="Contact Sarah Thompson at LinkedIn or visit our Boston office.",
        test_name="Test 9: Professional Context"
    ))
    
    # Test 10: Error case - empty text
    results.append(test_entity_extraction(
        text="",
        test_name="Test 10: Empty Text (Error Case)"
    ))
    
    # Test OCR integration if image provided
    ocr_result = test_ocr_with_entities(args.image)
    if ocr_result:
        results.append(ocr_result)
    
    # Print summary
    all_passed = print_summary(results)
    
    # Exit with appropriate code
    sys.exit(0 if all_passed else 1)

if __name__ == "__main__":
    main()
