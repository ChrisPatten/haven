# Haven.app Changes Required for New Architecture

## Overview

The new HostAgent architecture has been implemented in the backend Swift code. Haven.app needs some changes to fully utilize and configure the new architecture.

## Current State

- **Backend**: New architecture is implemented (TextExtractor, ImageExtractor, EnrichmentOrchestrator, DocumentSubmitter)
- **Collectors**: EmailCollector has new `collectAndSubmit()` method using new architecture
- **Handlers**: Still using old architecture (need to be updated)
- **Haven.app**: No changes yet - still uses old flow

## Required Changes

### 1. Update Handlers to Use New Architecture ⚠️ (Backend)

The handlers (`EmailImapHandler`, `LocalFSHandler`, `IMessageHandler`, etc.) need to be updated to use the new `collectAndSubmit()` method instead of the old `buildDocumentPayload()` + `submitEmailDocument()` flow.

**Files to update:**
- `hostagent/Sources/CollectorHandlers/Handlers/EmailImapHandler.swift`
- `hostagent/Sources/CollectorHandlers/Handlers/LocalFSHandler.swift`
- `hostagent/Sources/CollectorHandlers/Handlers/IMessageHandler.swift`
- `hostagent/Sources/CollectorHandlers/Handlers/ContactsHandler.swift` (skip enrichment)

**Changes needed:**
- Replace `buildDocumentPayload()` + `submitEmailDocument()` calls with `collectAndSubmit()`
- Pass enrichment orchestrator and submitter to collectors
- Handle `skipEnrichment` flag per collector

### 2. Add Per-Collector Enrichment Configuration UI ✅ (Haven.app)

Haven.app needs UI to configure per-collector enrichment settings.

**New Settings Section:**
- Add "Enrichment" section to Settings window
- Per-collector toggle for "Skip Enrichment"
- Global enrichment service toggles (OCR, Face Detection, NER, Captioning) - these come from `hostagent.yaml` but could be shown/configured in UI

**Files to create/modify:**
- `Haven/Haven/Settings/EnrichmentSettingsView.swift` (new)
- `Haven/Haven/Settings/SettingsWindow.swift` (add enrichment section)
- `Haven/Haven/Models/CollectorEnrichmentConfig.swift` (new model)

**Configuration Storage:**
- Store per-collector `skipEnrichment` flag in plist (e.g., `~/.haven/collector_enrichment.plist`)
- Format:
```xml
<dict>
    <key>email_imap</key>
    <dict>
        <key>skipEnrichment</key>
        <false/>
    </dict>
    <key>contacts</key>
    <dict>
        <key>skipEnrichment</key>
        <true/>
    </dict>
    <key>localfs</key>
    <dict>
        <key>skipEnrichment</key>
        <false/>
    </dict>
    <key>imessage</key>
    <dict>
        <key>skipEnrichment</key>
        <false/>
    </dict>
</dict>
```

### 3. Pass Enrichment Settings to Collectors ✅ (Haven.app)

When initializing collectors or running them, Haven.app needs to:
1. Load per-collector enrichment config from plist
2. Create enrichment orchestrator with config from `HavenConfig`
3. Pass `skipEnrichment` flag and orchestrator to collectors

**Files to modify:**
- `Haven/Haven/Controllers/HostAgentController.swift`
  - Load enrichment config when initializing collectors
  - Create `DocumentEnrichmentOrchestrator` instances
  - Create `BatchDocumentSubmitter` instances
  - Pass these to collector handlers

- `Haven/Haven/Controllers/EmailController.swift`
- `Haven/Haven/Controllers/LocalFSController.swift`
- `Haven/Haven/Controllers/IMessageController.swift`
- `Haven/Haven/Controllers/ContactsController.swift`
  - Accept enrichment orchestrator and submitter in init
  - Pass to handlers

### 4. Update Collector Handlers to Accept Enrichment Settings ⚠️ (Backend)

Handlers need to accept enrichment orchestrator and submitter, and pass them to collectors.

**Files to modify:**
- `hostagent/Sources/CollectorHandlers/Handlers/EmailImapHandler.swift`
  - Add `enrichmentOrchestrator` and `submitter` parameters to init
  - Pass to `EmailCollector.collectAndSubmit()`

- Similar changes for other handlers

### 5. Create ConfigManager for Enrichment Settings ✅ (Haven.app)

Create a new `EnrichmentConfigManager` to load/save per-collector enrichment settings.

**File to create:**
- `Haven/Haven/Managers/EnrichmentConfigManager.swift`

**Methods:**
- `loadEnrichmentConfig() -> CollectorEnrichmentConfig`
- `saveEnrichmentConfig(_ config: CollectorEnrichmentConfig)`
- `getSkipEnrichment(for collectorId: String) -> Bool`

## Implementation Priority

### Phase 1: Backend Updates (Required First)
1. ✅ Update handlers to use new `collectAndSubmit()` method
2. ✅ Update handlers to accept enrichment orchestrator and submitter
3. ✅ Test backend changes

### Phase 2: Haven.app Configuration (Can be done in parallel)
1. ✅ Create `EnrichmentConfigManager`
2. ✅ Create `CollectorEnrichmentConfig` model
3. ✅ Add enrichment settings UI
4. ✅ Update controllers to load and pass enrichment settings

### Phase 3: Integration
1. ✅ Connect UI to config manager
2. ✅ Pass settings from controllers to handlers
3. ✅ Test end-to-end flow

## Notes

- **Global enrichment service config** (OCR, Face, Entity, Caption) comes from `hostagent.yaml` via `ModulesConfig` - this is already loaded in `HavenConfig`
- **Per-collector `skipEnrichment`** comes from Haven.app plist - this is new
- **Contacts collector** should always skip enrichment (hardcoded in handler)
- **Enrichment orchestrator** is created once per collector type (shared instance)
- **Document submitter** can be shared across all collectors (single instance)

## Example Flow

```
Haven.app Settings UI
  └─> User toggles "Skip Enrichment" for email_imap
      └─> EnrichmentConfigManager.saveEnrichmentConfig()
          └─> Saved to ~/.haven/collector_enrichment.plist

Haven.app runs collector
  └─> HostAgentController.runCollector()
      └─> EmailController.run()
          └─> EmailImapHandler.runCollector()
              └─> Load skipEnrichment from EnrichmentConfigManager
              └─> Create DocumentEnrichmentOrchestrator (if not skipped)
              └─> Create BatchDocumentSubmitter
              └─> EmailCollector.collectAndSubmit(
                    enrichmentOrchestrator: orchestrator,
                    submitter: submitter,
                    skipEnrichment: skipEnrichment,
                    config: config
                  )
```

## Migration Path

1. **Backend first**: Update handlers to support both old and new architecture (feature flag)
2. **Haven.app**: Add configuration UI (can work with old architecture initially)
3. **Switch over**: Enable new architecture in handlers
4. **Cleanup**: Remove old architecture code after validation

