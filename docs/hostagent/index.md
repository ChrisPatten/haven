# HostAgent Overview

HostAgent is the native macOS companion to Haven. It unlocks capabilities that containers cannot access: iMessage collection, Vision-based OCR, filesystem monitoring, and link resolution. 

## Migration Status

**⚠️ Important**: HostAgent is currently being migrated into the unified Haven macOS app. The standalone HostAgent HTTP server is being phased out in favor of direct module integration within the Haven app.

### Current State

- **Phase 1 (Complete)**: UI components migrated from HavenUI to unified Haven app
- **Phase 2 (In Progress)**: HostAgent functionality integration - collector modules are being integrated directly into the Haven app
- **Phase 3 (Planned)**: Complete migration - remove legacy HostAgent HTTP server code

### What This Means

- **New users**: Use the unified Haven.app - it includes all HostAgent functionality
- **Existing users**: Your configuration at `~/.haven/hostagent.yaml` remains compatible
- **Development**: Collector modules are being refactored to work directly within the app instead of via HTTP API

## Why HostAgent Exists

HostAgent provides read-only access to privileged macOS resources that containers cannot access:

- **Messages Database**: Read-only access to iMessage history
- **Vision APIs**: Native macOS Vision framework for OCR and entity detection
- **Filesystem Monitoring**: FSEvents-based file watching
- **Contacts**: Access to macOS Contacts database
- **Email**: IMAP and local Mail.app email collection

## Architecture Evolution

### Legacy Architecture (Being Phased Out)

Previously, HostAgent ran as a separate HTTP server:

```
HavenUI (SwiftUI) → HTTP → HostAgent (localhost:7090) → Collectors → Gateway
```

### New Unified Architecture

The unified Haven app integrates collectors directly:

```
Haven App (SwiftUI) → Direct Swift APIs → Collector Modules → Gateway
```

**Benefits:**
- No HTTP overhead
- Simpler deployment (single app)
- Better error handling and state management
- Integrated UI and runtime

## Core Capabilities

The collector modules provide:

- **iMessage Collection**: Safe, read-only access to Messages.app database with smart snapshots
- **Email Collection**: IMAP and local Mail.app `.emlx` collection
- **File System Monitoring**: FSEvents-based file watching with presigned URL uploads
- **Contacts Collection**: macOS Contacts.app integration
- **OCR Service**: Vision framework OCR + entity extraction

## Configuration

Configuration is managed through:

1. **Settings UI**: Built-in settings window in Haven.app (`⌘,`)
2. **Config File**: `~/.haven/hostagent.yaml` (YAML format)

The unified app provides a comprehensive settings interface for all collector configuration, or you can edit the YAML file directly.

## Installation and Usage

See the [Haven App Guide](../guides/havenui.md) for installation and usage instructions. The unified app includes all HostAgent functionality.

### Legacy Installation (Reference Only)

For reference, the legacy HostAgent installation process was:

```bash
make -C hostagent install
make -C hostagent launchd
```

This is no longer needed with the unified app.

## Operational Tips

- Use the Haven app's Dashboard to monitor collector status
- Configure collectors via the Settings window (`⌘,`)
- Grant Full Disk Access and Contacts permissions in System Settings
- Check the Dashboard activity log for collector run results

## Related Documentation

- [Haven App Guide](../guides/havenui.md) - Unified macOS app documentation
- [Agents Overview](../guides/AGENTS.md) for network topology and orchestration rules
- [Local Development](../operations/local-dev.md) for instructions on running Haven alongside Docker services
- [Functional Guide](../reference/functional_guide.md) for how collectors feed downstream workflows
- [HostAgent README](hostagent-readme.md) - Legacy API reference (for migration reference)

_Note: This documentation reflects the migration in progress. The unified Haven app is the recommended way to use HostAgent functionality going forward._
