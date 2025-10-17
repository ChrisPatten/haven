# Haven Host Agent - Quick Start Checklist

## 🎯 Goal
Get the Haven Host Agent compiling, running, and serving basic endpoints.

## ☑️ Pre-Implementation Checklist

### 1. Environment Setup
- [ ] macOS 14.0+ (Sonoma or later)
- [ ] Xcode 15.0+ installed or Swift 5.9+ toolchain
- [ ] Homebrew installed (for dependencies)
- [ ] Haven gateway running (`docker compose up`)

### 2. Resolve Dependencies
```bash
cd hostagent
swift package resolve
```

**If Yams fails to resolve:**
```bash
# Option A: Use pre-resolved version
swift package update

# Option B: Switch to JSON config
# Edit Package.swift: remove Yams dependency
# Update Config.swift: use JSONDecoder for .json files instead
```

### 3. Fix Compilation Errors

**Create stub HostHTTP server:**
```bash
cat > Sources/HostHTTP/Server.swift << 'EOF'
import Foundation
import HavenCore

public struct HavenHTTPServer {
    let config: HavenConfig
    
    public init(config: HavenConfig) throws {
        self.config = config
    }
    
    public func start() async throws {
        print("🚀 Host Agent starting on 127.0.0.1:\(config.port)")
        print("⚠️  Stub server - no endpoints implemented yet")
        print("   See IMPLEMENTATION_GUIDE.md for next steps")
        
        // Keep running
        try await Task.sleep(for: .seconds(.max))
    }
}
EOF
```

**Test compilation:**
```bash
swift build
# Should succeed with warnings but no errors
```

### 4. Run Basic Server
```bash
# Create config
mkdir -p ~/.haven
cp Resources/default-config.yaml ~/.haven/hostagent.yaml

# Edit config - change auth secret!
sed -i '' 's/change-me/your-secret-here/g' ~/.haven/hostagent.yaml

# Run
swift run hostagent

# Expected output:
# 🚀 Host Agent starting on 127.0.0.1:7090
# ⚠️  Stub server - no endpoints implemented yet
```

## 🚀 Phase 1: Minimal Viable Server

### Implement Basic SwiftNIO Server (4-6 hours)

**Goal:** GET /v1/health returns JSON

**Files to create:**
1. `Sources/HostHTTP/Server.swift` - SwiftNIO bootstrap
2. `Sources/HostHTTP/Router.swift` - Route matching
3. `Sources/HostHTTP/Handlers/HealthHandler.swift` - Health endpoint

**Test success:**
```bash
# Start server
swift run hostagent &

# Test
curl http://localhost:7090/v1/health
# Expected: {"status":"healthy","started_at":"2025-...","version":"1.0.0"}
```

**Reference:** See IMPLEMENTATION_GUIDE.md Phase 1 for code examples

### Implement Auth Middleware (1-2 hours)

**Goal:** All endpoints require x-auth header

**Test success:**
```bash
# Should fail
curl http://localhost:7090/v1/health
# Expected: 401 Unauthorized

# Should succeed
curl -H "x-auth: your-secret-here" http://localhost:7090/v1/health
# Expected: 200 OK
```

### Implement OCR Endpoint (3-4 hours)

**Goal:** POST /v1/ocr processes images

**Files to create:**
1. `Sources/HostHTTP/Handlers/OCRHandler.swift`
2. `Sources/HostHTTP/MultipartParser.swift` (or use library)

**Test success:**
```bash
# Create test image with text
curl -H "x-auth: your-secret-here" \
  -F "file=@test-image.jpg" \
  http://localhost:7090/v1/ocr

# Expected:
# {
#   "ocr_text": "...",
#   "ocr_boxes": [...],
#   "lang": "en",
#   ...
# }
```

## 🎯 Phase 2: iMessage Collector

### Implement Database Reader (6-8 hours)

**Goal:** Read Messages.app database safely

**Files to create:**
1. `Sources/IMessages/IMessageDB.swift` - GRDB models
2. `Sources/IMessages/IMessageState.swift` - Cursor management
3. `Sources/IMessages/IMessageCollector.swift` - Main logic

**Test success:**
```bash
# Grant Full Disk Access first!
# System Settings > Privacy & Security > Full Disk Access

swift test --filter IMessageDBTests
```

### Implement Backfill Endpoint (4-6 hours)

**Goal:** POST /v1/collectors/imessage:run processes messages

**Test success:**
```bash
curl -H "x-auth: your-secret-here" \
  -X POST http://localhost:7090/v1/collectors/imessage:run \
  -H "Content-Type: application/json" \
  -d '{"mode":"backfill","batch_size":100,"max_rows":1000}'

# Check gateway received events
curl http://localhost:8085/v1/search?q=test
```

## 🚀 Phase 3: Production Ready

### LaunchAgent Setup (1 hour)

```bash
make install
make launchd

# Verify auto-start
launchctl list | grep haven
tail -f ~/Library/Logs/Haven/hostagent.log
```

### Testing (4-6 hours)

```bash
# Unit tests
swift test

# Integration test with real Messages DB
swift test --filter IMessageCollectorTests

# Performance test
# Target: >= 10k msgs/hour with OCR
```

### Update Docker Integration (1 hour)

**Edit `compose.yaml`:**
```yaml
services:
  gateway_api:
    environment:
      - HOST_AGENT_URL=http://host.docker.internal:7090
      - HOST_AGENT_AUTH=your-secret-here
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

**Test from container:**
```bash
docker compose exec gateway_api curl \
  -H "x-auth: your-secret-here" \
  http://host.docker.internal:7090/v1/health
```

## ✅ Success Criteria

### Minimal (Phase 1 Done)
- [ ] Server starts and binds to 127.0.0.1:7090
- [ ] GET /v1/health returns valid JSON
- [ ] Auth middleware enforces x-auth header
- [ ] POST /v1/ocr processes images with Vision
- [ ] OCR returns text and bounding boxes

### Production Ready (Phase 2 Done)
- [ ] iMessage backfill processes 10k+ messages
- [ ] OCR enrichment adds text to attachments
- [ ] Events posted to gateway successfully
- [ ] Cursor persists across restarts (no duplicates)
- [ ] LaunchAgent auto-starts on login
- [ ] Docker services can call host agent
- [ ] All tests pass

### Full Feature Set (Phase 3 Done)
- [ ] Tail mode detects new messages (< 5s latency)
- [ ] FSWatch monitors directories
- [ ] All stub modules report health status
- [ ] Prometheus metrics exposed
- [ ] Performance targets met (see README)

## 📚 Resources

- **Next implementation step**: See IMPLEMENTATION_GUIDE.md Phase 1
- **API examples**: See README.md API Reference section
- **Troubleshooting**: See README.md Troubleshooting section
- **Architecture**: See AGENTS.md
- **Original spec**: See your PRP document

## 🐛 Common Issues

### "No such module 'Yams'"
- Run `swift package resolve`
- Or remove Yams and use JSON config

### "Cannot find 'HavenLogger' in scope"
- Ensure `import HavenCore` at top of file
- Rebuild: `swift build --clean`

### "Permission denied" reading Messages
- Grant Full Disk Access
- System Settings > Privacy & Security > Full Disk Access
- Add `/usr/local/bin/hostagent`

### "Connection refused" from Docker
- Verify agent is running: `curl http://localhost:7090/v1/health`
- Check `extra_hosts` in compose.yaml
- Use `host.docker.internal` not `localhost`

## 🎓 Learning Resources

- **SwiftNIO**: https://github.com/apple/swift-nio
- **GRDB**: https://github.com/groue/GRDB.swift
- **Vision Framework**: https://developer.apple.com/documentation/vision
- **Swift Concurrency**: https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html

---

**Start with Phase 1 - Get that /v1/health endpoint working!**

Good luck! 🚀
