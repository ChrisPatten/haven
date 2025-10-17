#!/usr/bin/env python3
"""
Test script for FSWatch module functionality.

This script tests the file system watching capabilities of the Haven Host Agent.

Usage:
    python3 scripts/test_fswatch.py [test_directory]
    
If no test_directory is provided, creates a temporary directory for testing.
"""

import sys
import time
import requests
import json
import tempfile
import os
from pathlib import Path

# Configuration
HOSTAGENT_URL = "http://localhost:7090"
AUTH_TOKEN = "change-me"

HEADERS = {
    "Content-Type": "application/json",
    "x-auth": AUTH_TOKEN
}


def test_list_watches():
    """Test listing active watches."""
    print("\n=== Test: List Active Watches ===")
    
    response = requests.get(f"{HOSTAGENT_URL}/v1/fs-watches", headers=HEADERS)
    print(f"Status: {response.status_code}")
    print(f"Response: {json.dumps(response.json(), indent=2)}")
    
    assert response.status_code == 200, f"Expected 200, got {response.status_code}"
    data = response.json()
    assert data["status"] == "success", f"Expected success status"
    
    return data["data"]["watches"]


def test_add_watch(watch_path, watch_id="test-watch"):
    """Test adding a new watch."""
    print(f"\n=== Test: Add Watch (path={watch_path}) ===")
    
    payload = {
        "id": watch_id,
        "path": watch_path,
        "glob": "*.txt",
        "target": "gateway",
        "handoff": "presigned"
    }
    
    response = requests.post(
        f"{HOSTAGENT_URL}/v1/fs-watches",
        headers=HEADERS,
        json=payload
    )
    
    print(f"Status: {response.status_code}")
    print(f"Response: {json.dumps(response.json(), indent=2)}")
    
    assert response.status_code == 200, f"Expected 200, got {response.status_code}"
    data = response.json()
    assert data["status"] == "success", f"Expected success status"
    
    return data["data"]["id"]


def test_create_file(directory, filename="test.txt"):
    """Create a test file to trigger watch events."""
    print(f"\n=== Test: Create File ({filename}) ===")
    
    file_path = os.path.join(directory, filename)
    with open(file_path, "w") as f:
        f.write(f"Test content created at {time.time()}\n")
    
    print(f"Created: {file_path}")
    return file_path


def test_poll_events(wait_seconds=2):
    """Test polling for file system events."""
    print(f"\n=== Test: Poll Events (waiting {wait_seconds}s for debounce) ===")
    
    # Wait for debounce
    time.sleep(wait_seconds)
    
    response = requests.get(
        f"{HOSTAGENT_URL}/v1/fs-watches/events?limit=10",
        headers=HEADERS
    )
    
    print(f"Status: {response.status_code}")
    print(f"Response: {json.dumps(response.json(), indent=2)}")
    
    assert response.status_code == 200, f"Expected 200, got {response.status_code}"
    data = response.json()
    assert data["status"] == "success", f"Expected success status"
    
    return data["data"]["events"]


def test_poll_and_acknowledge():
    """Test polling events with acknowledgement."""
    print("\n=== Test: Poll and Acknowledge Events ===")
    
    response = requests.get(
        f"{HOSTAGENT_URL}/v1/fs-watches/events?limit=10&acknowledge=true",
        headers=HEADERS
    )
    
    print(f"Status: {response.status_code}")
    print(f"Response: {json.dumps(response.json(), indent=2)}")
    
    assert response.status_code == 200, f"Expected 200, got {response.status_code}"
    data = response.json()
    
    return data["data"]["events"]


def test_clear_events():
    """Test clearing all events."""
    print("\n=== Test: Clear All Events ===")
    
    response = requests.post(
        f"{HOSTAGENT_URL}/v1/fs-watches/events:clear",
        headers=HEADERS
    )
    
    print(f"Status: {response.status_code}")
    print(f"Response: {json.dumps(response.json(), indent=2)}")
    
    assert response.status_code == 200, f"Expected 200, got {response.status_code}"


def test_remove_watch(watch_id="test-watch"):
    """Test removing a watch."""
    print(f"\n=== Test: Remove Watch (id={watch_id}) ===")
    
    response = requests.delete(
        f"{HOSTAGENT_URL}/v1/fs-watches/{watch_id}",
        headers=HEADERS
    )
    
    print(f"Status: {response.status_code}")
    print(f"Response: {json.dumps(response.json(), indent=2)}")
    
    assert response.status_code == 200, f"Expected 200, got {response.status_code}"
    data = response.json()
    assert data["status"] == "success", f"Expected success status"


def test_health_check():
    """Test that FSWatch module is reported in health check."""
    print("\n=== Test: Health Check ===")
    
    response = requests.get(f"{HOSTAGENT_URL}/v1/health", headers=HEADERS)
    print(f"Status: {response.status_code}")
    
    data = response.json()
    print(f"Health Status: {data['status']}")
    
    # Find fswatch module
    fswatch_module = next((m for m in data["modules"] if m["name"] == "fswatch"), None)
    if fswatch_module:
        print(f"FSWatch Module: {json.dumps(fswatch_module, indent=2)}")
    else:
        print("Warning: FSWatch module not found in health check")


def run_comprehensive_test(test_dir=None):
    """Run all FSWatch tests."""
    print("╔════════════════════════════════════════════════╗")
    print("║  FSWatch Module Test Suite                     ║")
    print("╚════════════════════════════════════════════════╝")
    
    # Use provided directory or create temp one
    if test_dir:
        watch_dir = test_dir
        cleanup = False
    else:
        watch_dir = tempfile.mkdtemp(prefix="haven_fswatch_test_")
        cleanup = True
    
    print(f"\nTest directory: {watch_dir}")
    
    try:
        # Test 1: Health check
        test_health_check()
        
        # Test 2: List watches (should be empty initially)
        initial_watches = test_list_watches()
        print(f"Initial watches: {len(initial_watches)}")
        
        # Test 3: Add a watch
        watch_id = test_add_watch(watch_dir, watch_id="test-watch-1")
        print(f"Added watch: {watch_id}")
        
        # Test 4: Verify watch was added
        watches = test_list_watches()
        assert len(watches) == len(initial_watches) + 1, "Watch count should increase by 1"
        
        # Test 5: Create a file to trigger event
        test_file = test_create_file(watch_dir, "test1.txt")
        
        # Test 6: Poll for events
        events = test_poll_events(wait_seconds=1)
        print(f"\nReceived {len(events)} event(s)")
        
        if events:
            event = events[0]
            print(f"Event type: {event['type']}")
            print(f"Event path: {event['path']}")
            assert event['type'] in ['created', 'modified'], f"Unexpected event type: {event['type']}"
        
        # Test 7: Create more files
        test_create_file(watch_dir, "test2.txt")
        test_create_file(watch_dir, "test3.txt")
        
        # Test 8: Poll and acknowledge
        events = test_poll_events(wait_seconds=1)
        print(f"\nReceived {len(events)} more event(s)")
        
        # Test 9: Acknowledge events
        if events:
            test_poll_and_acknowledge()
            
            # Verify events were acknowledged
            remaining_events = test_poll_events(wait_seconds=0)
            print(f"Remaining events after acknowledgement: {len(remaining_events)}")
        
        # Test 10: Clear events
        test_clear_events()
        
        # Test 11: Remove watch
        test_remove_watch(watch_id)
        
        # Test 12: Verify watch was removed
        final_watches = test_list_watches()
        assert len(final_watches) == len(initial_watches), "Watch count should return to initial"
        
        print("\n✅ All tests passed!")
        
    except Exception as e:
        print(f"\n❌ Test failed: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
        
    finally:
        # Cleanup
        if cleanup and os.path.exists(watch_dir):
            import shutil
            shutil.rmtree(watch_dir)
            print(f"\nCleaned up test directory: {watch_dir}")


def main():
    """Main entry point."""
    test_dir = sys.argv[1] if len(sys.argv) > 1 else None
    
    if test_dir and not os.path.isdir(test_dir):
        print(f"Error: {test_dir} is not a valid directory")
        sys.exit(1)
    
    try:
        # Quick connectivity check
        response = requests.get(f"{HOSTAGENT_URL}/v1/health", headers=HEADERS, timeout=2)
        if response.status_code != 200:
            print(f"Error: Host agent not responding correctly (status: {response.status_code})")
            sys.exit(1)
    except requests.exceptions.RequestException as e:
        print(f"Error: Cannot connect to host agent at {HOSTAGENT_URL}")
        print(f"Make sure hostagent is running with: cd hostagent && swift run hostagent")
        sys.exit(1)
    
    run_comprehensive_test(test_dir)


if __name__ == "__main__":
    main()
