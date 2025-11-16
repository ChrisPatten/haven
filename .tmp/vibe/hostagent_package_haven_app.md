
## TODO: Remove HTTP Conversion from HostAgent → Haven.app Integration

### **HostAgent Package Changes**

#### **1. Add Direct Swift APIs to Handlers**

**1.1 IMessageHandler** (`hostagent/Sources/HostHTTP/Handlers/IMessageHandler.swift`)
- [ ] Add `public func runCollector(request: CollectorRunRequest?) async throws -> RunResponse`
  - Extract logic from `handleRun` that parses HTTPRequest and converts to CollectorParams
  - Call existing `collectMessages` method
  - Convert `CollectorStats` to `RunResponse.Stats`
  - Return `RunResponse` directly (not HTTPResponse)
  - Handle errors by setting `RunResponse.status = .error`
  - Keep `handleRun` for backward compatibility (mark deprecated)
- [ ] Add `public func getCollectorState() async -> CollectorStateInfo`
  - Extract state logic from `handleState`
  - Return a struct with `isRunning`, `lastRunTime`, `lastRunStatus`, `lastRunStats`, `lastRunError`
  - Keep `handleState` for backward compatibility (mark deprecated)
- [ ] Add helper: `private func convertCollectorRunRequest(_ request: CollectorRunRequest?) -> CollectorParams`
  - Extract parameter conversion logic from `handleRun`
  - Handle scope extraction for iMessage-specific fields
  - Convert DateRange, timeWindow, etc.

**1.2 ContactsHandler** (`hostagent/Sources/HostHTTP/Handlers/ContactsHandler.swift`)
- [ ] Add `public func runCollector(request: CollectorRunRequest?) async throws -> RunResponse`
  - Extract collection logic from `handleRun`
  - Convert internal stats to `RunResponse.Stats`
  - Return `RunResponse` directly
  - Keep `handleRun` for backward compatibility (mark deprecated)
- [ ] Add `public func getCollectorState() async -> CollectorStateInfo`
  - Extract state logic from `handleState`
  - Return state struct
  - Keep `handleState` for backward compatibility (mark deprecated)

**1.3 LocalFSHandler** (`hostagent/Sources/HostHTTP/Handlers/LocalFSHandler.swift`)
- [ ] Add `public func runCollector(request: CollectorRunRequest?) async throws -> RunResponse`
  - Extract collection logic from `handleRun`
  - Convert `CollectorStats.toDict()` to `RunResponse.Stats`
  - Return `RunResponse` directly
  - Handle scope extraction for LocalFS-specific paths/globs
  - Keep `handleRun` for backward compatibility (mark deprecated)
- [ ] Add `public func getCollectorState() async -> CollectorStateInfo`
  - Extract state logic from `handleState`
  - Return state struct
  - Keep `handleState` for backward compatibility (mark deprecated)

**1.4 EmailImapHandler** (`hostagent/Sources/HostHTTP/Handlers/EmailImapHandler.swift`)
- [ ] Add `public func runCollector(request: CollectorRunRequest?) async throws -> RunResponse`
  - Extract collection logic from `handleRun`
  - Handle `Components.Schemas.RunRequest` → `CollectorRunRequest` conversion
  - Extract IMAP scope fields (connection, folders)
  - Convert internal stats to `RunResponse.Stats`
  - Return `RunResponse` directly
  - Keep `handleRun` for backward compatibility (mark deprecated)

#### **2. Create Shared State Types**

**2.1 Add CollectorStateInfo** (`hostagent/Sources/HavenCore/` or new file)
- [ ] Create `public struct CollectorStateInfo: Codable`
  ```swift
  public struct CollectorStateInfo {
      public let isRunning: Bool
      public let lastRunTime: Date?
      public let lastRunStatus: String?
      public let lastRunStats: [String: AnyCodable]?
      public let lastRunError: String?
  }
  ```
- [ ] Use this across all handlers for state queries

#### **3. Update RunResponse Type**

**3.1 Ensure RunResponse is Public** (`hostagent/Sources/HostAgent/Collectors/RunResponse.swift`)
- [ ] Verify `RunResponse` is public (already is)
- [ ] Verify `RunResponse.Stats` is public (already is)
- [ ] Verify `RunResponse.Status` enum is public (already is)
- [ ] Document that this is the standard return type for direct Swift APIs

#### **4. Update Status/Health Handlers**

**4.1 HealthHandler** (`hostagent/Sources/HostHTTP/Handlers/HealthHandler.swift`)
- [ ] Add `public func getStatus() async -> StatusResponse`
  - Extract status logic from `handleHealth`
  - Return struct with status, uptime, version, modules
  - Keep `handleHealth` for backward compatibility (mark deprecated)

**4.2 ModulesHandler** (`hostagent/Sources/HostHTTP/Handlers/ModulesHandler.swift`)
- [ ] Add `public func getModuleSummaries() async -> [ModuleSummary]`
  - Extract module summary logic
  - Return array directly
  - Keep `handleModules` for backward compatibility (mark deprecated)

**4.3 CapabilitiesHandler** (`hostagent/Sources/HostHTTP/Handlers/CapabilitiesHandler.swift`)
- [ ] Add `public func getCapabilities() async -> CapabilitiesResponse`
  - Extract capabilities logic
  - Return struct directly
  - Keep `handleCapabilities` for backward compatibility (mark deprecated)

#### **5. Update Service Controllers**

**5.1 OCRService, EntityService, FSWatchService**
- [ ] Verify all service types are public and can be accessed directly
- [ ] No changes needed if they're already public

### **Haven.app Controller Changes**

#### **6. Update IMessageController** (`Haven/Haven/Controllers/IMessageController.swift`)

- [ ] Remove `createHTTPRequest(from:)` method
- [ ] Remove `convertToRunResponse(httpResponse:collectorId:)` method
- [ ] Remove `wrapAdapterPayload(_:collectorId:)` method
- [ ] Remove `convertHostAgentResponse(_:collectorId:)` method
- [ ] Remove `convertModelsResponse(_:collectorId:)` method
- [ ] Remove `HostAgentRunResponse` and `HostAgentStats` helper structs
- [ ] Update `run(request:)` method:
  ```swift
  public func run(request: CollectorRunRequest?) async throws -> RunResponse {
      let currentlyRunning = await isRunning()
      guard !currentlyRunning else {
          throw CollectorError.alreadyRunning
      }
      
      baseState.isRunning = true
      
      do {
          // Call handler directly - no HTTP conversion!
          let runResponse = try await handler.runCollector(request: request)
          
          baseState.updateState(from: runResponse)
          baseState.isRunning = false
          
          return runResponse
      } catch {
          baseState.isRunning = false
          baseState.lastRunError = error.localizedDescription
          throw error
      }
  }
  ```
- [ ] Update `getState()` method:
  ```swift
  public func getState() async -> CollectorStateResponse? {
      let stateInfo = await handler.getCollectorState()
      
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      
      return CollectorStateResponse(
          isRunning: stateInfo.isRunning,
          lastRunStatus: stateInfo.lastRunStatus,
          lastRunTime: stateInfo.lastRunTime.map { formatter.string(from: $0) },
          lastRunStats: stateInfo.lastRunStats?.compactMapValues { /* convert to UI AnyCodable */ },
          lastRunError: stateInfo.lastRunError
      )
  }
  ```

#### **7. Update ContactsController** (`Haven/Haven/Controllers/ContactsController.swift`)

- [ ] Remove all HTTP conversion methods (same as IMessageController)
- [ ] Update `run(request:)` to call `handler.runCollector(request:)` directly
- [ ] Update `getState()` to call `handler.getCollectorState()` directly
- [ ] Remove `HostAgentRunResponse` and `HostAgentStats` helper structs

#### **8. Update LocalFSController** (`Haven/Haven/Controllers/LocalFSController.swift`)

- [ ] Remove all HTTP conversion methods
- [ ] Update `run(request:)` to call `handler.runCollector(request:)` directly
- [ ] Update `getState()` to call `handler.getCollectorState()` directly
- [ ] Remove `HostAgentRunResponse` and `HostAgentStats` helper structs

#### **9. Update EmailController** (`Haven/Haven/Controllers/EmailController.swift`)

- [ ] Remove all HTTP conversion methods
- [ ] Update `run(request:)` to call `handler.runCollector(request:)` directly
- [ ] Remove `HostAgentRunResponse` and `HostAgentStats` helper structs
- [ ] Note: EmailImapHandler may not have `getState()` - handle accordingly

#### **10. Update ServiceController** (`Haven/Haven/Controllers/ServiceController.swift`)

- [ ] Verify it uses direct initialization (no HTTP)
- [ ] No changes needed if it's already using direct APIs

#### **11. Update StatusController** (`Haven/Haven/Controllers/StatusController.swift`)

- [ ] Consider using `HealthHandler.getStatus()` if needed
- [ ] Consider using `ModulesHandler.getModuleSummaries()` if needed
- [ ] Or keep current implementation if it's sufficient

#### **12. Update HostAgentController** (`Haven/Haven/Controllers/HostAgentController.swift`)

- [ ] Verify all collector initialization uses direct APIs
- [ ] Update any status/health checks to use direct APIs if needed
- [ ] No major changes expected if controllers are updated correctly

#### **13. Remove Stub Files** (after real package is integrated)

- [ ] Remove `Haven/Haven/Stubs/HavenCoreStub.swift`
- [ ] Remove `Haven/Haven/Stubs/HostHTTPStub.swift`
- [ ] Remove `Haven/Haven/Stubs/ServiceStubs.swift`
- [ ] Update imports in controllers to use real packages:
  - `import HavenCore`
  - `import HostHTTP` (or individual handler modules)
  - `import OCR`
  - `import Entity`
  - `import FSWatch`

#### **14. Update Models** (`Haven/Haven/Models.swift`)

- [ ] Use hostagent's `RunResponse` directly (import from package)
- [ ] Use hostagent's `CollectorRunRequest` directly (import from package)

### **Type Compatibility & Imports**

#### **16. Update Package Dependencies**

- [ ] Add hostagent package as Swift Package dependency to Haven.xcodeproj
  - Add local package reference: `hostagent/Package.swift`
- [ ] Link required products:
  - `HavenCore`
  - `OCR`, `Entity`, `FSWatch` as needed
- [ ] Remove stub imports once package is integrated

### **Testing & Verification**

#### **17. Verify Direct API Calls Work**

- [ ] Test IMessageController.run() with direct API
- [ ] Test ContactsController.run() with direct API
- [ ] Test LocalFSController.run() with direct API
- [ ] Test EmailController.run() with direct API
- [ ] Test all getState() methods
- [ ] Verify error handling works correctly
- [ ] Verify state tracking works correctly

#### **18. Clean Up Deprecated Code** (optional, for future)

- [ ] Remove all HTTP handlers and related code

### **Documentation**

#### **19. Update Architecture Docs**

- [ ] Update `AGENTS.md` to reflect that hostagent runs in-app, not as daemon
- [ ] Document the direct Swift API pattern
- [ ] Update any API documentation to show both patterns (HTTP for backward compat, Swift for in-app)

### **Summary of Changes**

**HostAgent Package:**
- Add direct Swift APIs to all handlers (`runCollector`, `getCollectorState`)
- Create shared `CollectorStateInfo` type
- Add direct APIs to Health/Modules/Capabilities handlers
- Remove HTTP handlers

**Haven.app:**
- Remove all HTTP request/response conversion code
- Update controllers to call direct Swift APIs
- Remove stub files once package is integrated
- Resolve type conflicts (use hostagent types where possible)
- Add Swift Package dependency for hostagent

**Result:**
- Clean direct Swift APIs between Haven.app and hostagent
- No HTTP conversion overhead
- Simpler, more maintainable code
- Better type safety and error handling
