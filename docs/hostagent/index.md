# Collector Implementation

Haven.app uses Swift collector modules to access macOS system resources. These collectors are integrated directly into Haven.app and run via Swift APIs (no HTTP server required).

## Overview

The collector modules provide native macOS capabilities that containers cannot access:

- **Messages Database**: Read-only access to iMessage history
- **Vision APIs**: Native macOS Vision framework for OCR and entity detection
- **Filesystem Monitoring**: FSEvents-based file watching
- **Contacts**: Access to macOS Contacts database
- **Email**: IMAP and local Mail.app email collection

## Architecture

Haven.app integrates collectors directly:

```
Haven.app (SwiftUI) → Direct Swift APIs → Collector Modules → Gateway API
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

## Usage

See the [Haven.app Guide](../guides/havenui.md) for installation and usage instructions.

## Collector Documentation

- [iMessage Collector](../guides/collectors/imessage.md) - iMessage collection
- [Local Files Collector](../guides/collectors/localfs.md) - Filesystem watching
- [Contacts Collector](../guides/collectors/contacts.md) - Contacts sync
- [Email Collectors](../guides/collectors/email.md) - IMAP and Mail.app

## Implementation Details

The collector modules are implemented as Swift packages within Haven.app:

- **HavenCore**: Core collector infrastructure
- **Collectors**: Individual collector implementations
- **Utilities**: OCR, file watching, link resolution

For implementation details, see the source code in `hostagent/Sources/` and `Haven/Haven/`.

## Related Documentation

- [Haven.app Guide](../guides/havenui.md) - App usage and configuration
- [Architecture Overview](../architecture/overview.md) - System architecture
- [Local Development](../operations/local-dev.md) - Development setup
- [Functional Guide](../reference/functional_guide.md) - Ingestion workflows
