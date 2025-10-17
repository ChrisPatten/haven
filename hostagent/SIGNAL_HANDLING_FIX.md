# Signal Handling Fix

## Problem

The hostagent application did not respond to Ctrl-C (SIGINT) and had to be force-quit from Activity Monitor.

## Root Cause

The original signal handling implementation had two critical issues:

1. **Async/Await in Signal Handler**: The code attempted to use `await` inside the C `signal()` callback, which is a synchronous context:
   ```swift
   signal(SIGINT) { _ in
       Task {
           await SignalWaiter.shared.signal()  // ❌ Won't work reliably
       }
   }
   ```

2. **Instance Mismatch**: The code created a local `SignalWaiter` instance but referenced `SignalWaiter.shared` in the signal handlers, while waiting on the local instance.

## Solution

Replaced the broken signal handling with a proper implementation using `DispatchSourceSignal`:

```swift
final class SignalWaiter: @unchecked Sendable {
    static let shared = SignalWaiter()
    
    private var continuation: CheckedContinuation<Void, Never>?
    private var signalSources: [DispatchSourceSignal] = []
    private let lock = NSLock()
    
    private init() {
        setupSignalSource(for: SIGINT)
        setupSignalSource(for: SIGTERM)
    }
    
    private func setupSignalSource(for sig: Int32) {
        // Ignore default signal handler
        Darwin.signal(sig, SIG_IGN)
        
        // Use DispatchSource for async-safe signal handling
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { [weak self] in
            self?.triggerShutdown()
        }
        source.resume()
        signalSources.append(source)
    }
    
    private func triggerShutdown() {
        lock.lock()
        continuation?.resume()
        continuation = nil
        lock.unlock()
    }
}
```

### Key Changes

- **DispatchSourceSignal**: Uses the proper async-safe mechanism for signal handling in Swift
- **Signal Masking**: Calls `Darwin.signal(sig, SIG_IGN)` to prevent default termination
- **Thread Safety**: Uses `NSLock` to protect shared state (`continuation`)
- **@unchecked Sendable**: Marks class as Sendable with manual synchronization

## Verification

Tested with both SIGINT (Ctrl-C) and SIGTERM:

```bash
# Start server
.build/debug/hostagent &

# Test SIGINT
pkill -INT hostagent  # ✅ Exits gracefully

# Test SIGTERM  
pkill -TERM hostagent  # ✅ Exits gracefully
```

The application now:
- Responds immediately to Ctrl-C in terminal
- Shuts down gracefully on SIGTERM
- Properly cleans up resources before exit
- No longer requires force-quit from Activity Monitor

## Files Changed

- `hostagent/Sources/HostAgent/main.swift` - Fixed signal handling implementation
