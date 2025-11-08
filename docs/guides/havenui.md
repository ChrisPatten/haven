# Haven - macOS Menu Bar Application

Haven is a native macOS menu bar application that provides a unified interface for managing collectors, viewing status, and running data collection tasks. It combines the functionality of the original HavenUI menubar app and HostAgent service into a single integrated application.

## Overview

Haven is a SwiftUI-based menu bar app that:

- **Integrated collector runtime**: Directly runs collectors without requiring a separate HTTP server
- **Monitors health status**: Real-time status indicator (green/yellow/red) in the menu bar
- **Dashboard view**: Overview of recent collector activity and system status
- **Collectors management**: View available collectors and trigger collection runs
- **Settings management**: Comprehensive configuration UI for all collectors and system settings
- **Process control**: Manual start/stop controls for the collector runtime

## Key Features

### Status Indicator

The menu bar icon changes color to reflect system status:

- 🟢 **Green**: Collector runtime is running and healthy
- 🟡 **Yellow**: Collector runtime is running but health checks are failing/pending
- 🔴 **Red**: Collector runtime is stopped

### Unified Architecture

Haven.app:

- **Direct module integration**: Calls collector modules directly via Swift APIs
- **No HTTP server**: Eliminates the need for a separate localhost HTTP service
- **Simplified deployment**: Single app bundle instead of separate UI and daemon components
- **Better performance**: Direct function calls instead of HTTP overhead

### Dashboard

Access via the menu bar or `⌘1`:

- **Status Overview**: Current health status and runtime state
- **Recent Activity**: Last collector runs with timestamps, status, and statistics
- **Quick Actions**: Start/stop runtime, run all collectors

### Collectors View

Access via the menu bar or `⌘2`:

- **Available Collectors**: Lists all configured collectors (iMessage, email, files, contacts)
- **Last Run Information**: Timestamp, status, and error details for each collector
- **Individual Controls**: Run specific collectors on demand
- **Run Configuration**: Advanced parameters for collector runs (simulate mode, limits, scopes, etc.)
- **Collector Details**: View detailed information about each collector including state and configuration

### Settings Window

Access via the menu bar or `⌘,`:

- **General Settings**: Gateway URL, API timeouts, status TTL
- **Collector Configuration**: Configure each collector type (iMessage, Email, Files, Contacts)
- **Schedules**: Set up automatic collector runs
- **Advanced**: System-level configuration options

## Installation

### Prerequisites

- macOS 14.0+ (Sonoma or later)
- Xcode 15.0+ or Swift 5.9+ toolchain
- Haven configuration at `~/.haven/hostagent.yaml` (compatible with legacy config format)

### Build and Run

```bash
cd Haven
open Haven.xcodeproj
# Build and run from Xcode (⌘R)
```

Or build from command line:

```bash
cd Haven
xcodebuild -scheme Haven -configuration Release
# App bundle will be in build/Release/Haven.app
```

### First Launch

On first launch, Haven will:

1. Check for Full Disk Access permission (required for iMessage collection)
2. Automatically open the Collectors window
3. Load configuration from `~/.haven/hostagent.yaml`
4. Initialize the collector runtime

## Configuration

Haven uses the standard configuration file at `~/.haven/hostagent.yaml`. The app includes a built-in settings UI for managing configuration, or you can edit the YAML file directly.

### Configuration Management

The app provides a comprehensive settings interface accessible via `⌘,`:

- **General**: Gateway URL, API configuration
- **Collectors**: Per-collector settings (iMessage, Email IMAP, Local Files, Contacts)
- **Schedules**: Automatic collector run schedules
- **Advanced**: System-level options

Changes made in the settings UI are automatically saved to the configuration file.

### Health Monitoring

Haven monitors the collector runtime health internally. The status indicator updates based on:

- Runtime initialization status
- Collector execution results
- Gateway connectivity
- Permission availability (Full Disk Access, Contacts)

## Usage

### Starting Haven

1. Launch Haven from Applications or the command line
2. The app appears in the menu bar with a status indicator
3. The Collectors window opens automatically
4. Click "Start" in the menu or Collectors window to initialize the runtime
5. Wait a moment for the indicator to turn green

### Running Collectors

**Run All Collectors:**
1. Click the menu bar icon
2. Select "Run All Collectors"
3. View progress in the Dashboard or Collectors window
4. Notifications appear as each collector completes

**Run Individual Collector:**
1. Click the menu bar icon → "Collectors" (or press `⌘2`)
2. Select a collector from the sidebar
3. Click the ▶️ button or use "Run" from the menu
4. View progress and results in the activity log

**Advanced Options:**
1. Open Collectors view
2. Select a collector
3. Click "Run with Options" to configure:
   - Simulate mode
   - Limits (message count, date ranges)
   - Scope filters (folders, contacts, file patterns)
   - Batch size and other collector-specific options

### Viewing Activity

1. Click the menu bar icon → "Dashboard" (or press `⌘1`)
2. Review recent collector runs in the activity list
3. Check timestamps, items processed, and any errors
4. Use this to verify collectors are running as expected

### Manual Control

If you need to manually control the runtime:

**Stop runtime:**
1. Click the menu bar icon
2. Click "Stop"
3. Wait for the indicator to turn red

**Start runtime:**
1. Click the menu bar icon
2. Click "Start"
3. Wait for the indicator to turn green

### Troubleshooting

**Menu bar icon is red:**
- Click "Start" to initialize the runtime
- Check configuration file at `~/.haven/hostagent.yaml`
- Verify Gateway is accessible at the configured URL
- Check Console.app for error messages

**Menu bar icon is yellow:**
- Runtime is running but health checks are failing
- Check that collectors have required permissions (Full Disk Access, Contacts)
- Verify Gateway connectivity and authentication
- Review error messages in the Dashboard

**Collectors fail to run:**
- Ensure runtime is started (green status)
- Check that collectors are enabled in settings
- Review error messages in the Dashboard activity log
- Verify permissions are granted in System Settings

**Permission Issues:**
- **Full Disk Access**: Required for iMessage collection
  - System Settings → Privacy & Security → Full Disk Access
  - Add Haven.app to the list
- **Contacts**: Required for contacts collection
  - System Settings → Privacy & Security → Contacts
  - Enable Haven.app

## Architecture

### Components

**HavenApp:**
- Main SwiftUI app entry point
- Manages app lifecycle and window management
- Coordinates between UI and runtime

**HostAgentController:**
- Main orchestration controller for collector runtime
- Manages collector lifecycle and execution
- Coordinates with ServiceController for backend services

**ServiceController:**
- Manages Gateway API communication
- Handles configuration loading and validation
- Provides service health monitoring

**Collector Controllers:**
- Individual controllers for each collector type (IMessage, Email, LocalFS, Contacts)
- Direct integration with collector handler modules
- Progress reporting and state management

**AppState:**
- Observable state container
- Tracks health, process state, collector status
- Persists last run information

**JobManager:**
- Manages async collector job execution
- Tracks job progress and completion
- Provides job cancellation support

### Communication Flow

```
Haven App (SwiftUI)
    ↓
HostAgentController (Orchestration)
    ↓
Collector Controllers (Direct Swift APIs)
    ↓
Collector Handlers (Modules)
    ↓
Gateway API (host.docker.internal:8085)
    ↓
Haven Services (Docker)
```

All collector operations happen via direct Swift API calls within Haven.app. No HTTP server is required.

## Development

### Building

```bash
cd Haven
xcodebuild -scheme Haven -configuration Debug
```

### Running in Debug Mode

```bash
# From Xcode: ⌘R
# Or from command line:
open build/Debug/Haven.app
```

### Testing

```bash
# Run unit tests
xcodebuild test -scheme Haven

# Run UI tests
xcodebuild test -scheme Haven -destination 'platform=macOS'
```

### Viewing Logs

Haven logs to the standard macOS Console. To view logs:

```bash
# Filter Haven logs
log stream --predicate 'process == "Haven"' --level debug

# Or use Console.app and filter for "Haven"
```

## Migration from HavenUI + HostAgent

If you were previously using the separate HavenUI and HostAgent applications:

1. **Configuration**: Your existing `~/.haven/hostagent.yaml` configuration file is compatible
2. **No HTTP server**: You no longer need to run HostAgent as a separate service
3. **Single app**: Launch Haven.app instead of HavenUI
4. **Same functionality**: All features from both apps are available in the unified interface

The unified app maintains feature parity with both HavenUI and HostAgent while providing a simpler, more integrated experience.

## Related Documentation

- [Collector Implementation](../hostagent/index.md) - Collector architecture and implementation
- [Architecture Overview](../architecture/overview.md) - System architecture and data flow
- [Local Development](../operations/local-dev.md) - Setting up Haven for development
