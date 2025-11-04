# HavenUI - macOS Menu Bar Application

HavenUI is a native macOS menu bar application that provides a convenient interface for managing Haven's hostagent service and running collectors.

## Overview

HavenUI is a SwiftUI-based menu bar app that:

- **Auto-manages hostagent lifecycle**: Automatically starts hostagent on launch and stops it on quit
- **Monitors health status**: Real-time status indicator (green/yellow/red) in the menu bar
- **Dashboard view**: Overview of recent collector activity and system status
- **Collectors management**: View available collectors and trigger collection runs
- **Process control**: Manual start/stop controls for hostagent when needed

## Key Features

### Status Indicator

The menu bar icon changes color to reflect system status:

- 🟢 **Green**: Hostagent is running and healthy
- 🟡 **Yellow**: Hostagent process is running but health checks are failing/pending
- 🔴 **Red**: Hostagent is stopped

### Automatic Lifecycle Management

**On Launch:**
- Checks if hostagent is already running
- Automatically starts hostagent as a child process
- Waits 0.5 seconds for initialization before starting health polling

**On Quit:**
- Gracefully terminates the hostagent child process (SIGTERM)
- Waits up to 2 seconds for shutdown to complete
- Force kills (SIGKILL) if graceful shutdown fails

This ensures hostagent runs **only when HavenUI is active**, providing a seamless user experience. 
HavenUI manages hostagent as a direct child process, not as a system service.

### Shutdown Safeguards

HavenUI employs multiple layers to guarantee hostagent stops on exit:

1. Graceful shutdown via `applicationWillTerminate` (SIGTERM to hostagent + wait + SIGKILL fallback)
2. Signal handlers for `SIGTERM` and `SIGINT` (ensure hostagent is terminated if HavenUI is killed externally)
3. `atexit` fallback for normal process exits (best-effort final kill if still running)

This combination covers user menu quits, command-line termination, and external system signals.

### Dashboard

Access via the menu bar or `⌘1`:

- **Status Overview**: Current health status and process state
- **Recent Activity**: Last 10 collector runs with timestamps, status, and statistics
- **Quick Actions**: Start/stop hostagent, run all collectors

### Collectors View

Access via the menu bar or `⌘2`:

- **Available Collectors**: Lists all configured collectors (iMessage, email, files, contacts)
- **Last Run Information**: Timestamp, status, and error details for each collector
- **Individual Controls**: Run specific collectors on demand
- **Request Builder**: Advanced parameters for collector runs (simulate mode, limits, etc.)

## Installation

### Prerequisites

- macOS 14.0+ (Sonoma or later)
- Xcode 15.0+ or Swift 5.9+ toolchain
- hostagent installed at `/usr/local/bin/hostagent`
- Haven configuration at `~/.haven/hostagent.yaml`

### Build and Run

```bash
cd HavenUI
swift build -c release

# Run directly
.build/release/HavenUI

# Or create an Xcode project and build as app bundle
swift package generate-xcodeproj
open HavenUI.xcodeproj
# Build and run from Xcode
```

## Configuration

HavenUI uses the standard hostagent configuration at `~/.haven/hostagent.yaml`. No additional configuration is required.

### Health Polling

HavenUI polls the hostagent health endpoint every 5 seconds to update status. The health check:

- Connects to `http://localhost:7090/v1/health`
- Uses a 3-second timeout for fast failure detection
- Updates the menu bar icon color based on response

### Process Management

HavenUI manages hostagent as a direct child process:

- **Binary**: `/usr/local/bin/hostagent`
- **Config**: `~/.haven/hostagent.yaml`
- **Logs**: `~/Library/Logs/Haven/hostagent.log` and `hostagent-error.log`
- **Lifecycle**: Starts on HavenUI launch, terminates on HavenUI quit

hostagent runs as a child process of HavenUI, not as a system service. This ensures:
- hostagent only runs when you're actively using HavenUI
- No background system services or LaunchAgents
- Clean shutdown when HavenUI quits

## Usage

### Starting Haven

1. Launch HavenUI from Applications or the command line
2. The app appears in the menu bar with a status indicator
3. Hostagent automatically starts if not already running
4. Wait a moment for the indicator to turn green

### Running Collectors

**Run All Collectors:**
1. Click the menu bar icon
2. Select "Run All Collectors"
3. Notifications appear as each collector completes
4. View results in the Dashboard

**Run Individual Collector:**
1. Click the menu bar icon → "Collectors" (or press `⌘2`)
2. Click the ▶️ button next to the desired collector
3. View progress and results in the activity log

**Advanced Options:**
1. Open Collectors view
2. Click "Advanced" for a collector
3. Configure parameters (simulate mode, limits, date ranges)
4. Click "Run with Options"

### Viewing Activity

1. Click the menu bar icon → "Dashboard" (or press `⌘1`)
2. Review recent collector runs in the activity list
3. Check timestamps, items processed, and any errors
4. Use this to verify collectors are running as expected

### Manual Control

If you need to manually control hostagent:

**Stop hostagent:**
1. Click the menu bar icon
2. Click "Stop"
3. Wait for the indicator to turn red

**Start hostagent:**
1. Click the menu bar icon
2. Click "Start"
3. Wait for the indicator to turn green

### Troubleshooting

**Menu bar icon is red:**
- Check if hostagent binary exists at `/usr/local/bin/hostagent`
- Verify config file at `~/.haven/hostagent.yaml`
- Check logs at `~/Library/Logs/Haven/hostagent-error.log`

**Menu bar icon is yellow:**
- Hostagent is running but health checks are failing
- Check if hostagent has required permissions (Full Disk Access)
- Verify the auth secret in config matches what HavenUI expects
- Check logs for permission or configuration errors

**Collectors fail to run:**
- Ensure hostagent is running (green status)
- Check that collectors are enabled in `hostagent.yaml`
- Review error messages in the Dashboard activity log
- Check hostagent logs for detailed error information

**HavenUI won't quit:**
- Force quit via Activity Monitor if needed
- Hostagent will continue running until next HavenUI launch
- Use `launchctl kill TERM gui/$(id -u)/com.haven.hostagent` to stop manually

## Architecture

### Components

**AppDelegate:**
- Manages app lifecycle (launch, terminate)
- Initializes services (client, poller, launch agent manager)
- Handles auto-start/stop of hostagent

**HostAgentClient:**
- HTTP client for hostagent API
- Handles authentication
- Provides async/await interface for all endpoints

**HealthPoller:**
- Background task checking hostagent health every 5 seconds
- Updates app state with current status
- Handles connection failures gracefully

**HostAgentProcessManager:**
- Manages hostagent as a child process
- Handles process lifecycle (start/stop/monitor)
- Configures logging and environment
- Ensures clean shutdown on termination

**AppState:**
- Observable state container
- Tracks health, process state, collector status
- Persists last run information to UserDefaults

### Communication Flow

```
HavenUI (SwiftUI)
    ↓
AppState (Observable)
    ↓
HostAgentClient (HTTP)
    ↓
hostagent (localhost:7090)
    ↓
Gateway (host.docker.internal:8085)
    ↓
Haven Services (Docker)
```

## Development

### Building

```bash
cd HavenUI
swift build
```

### Running in Debug Mode

```bash
swift run
```

### Testing Process Management

```bash
# Start HavenUI
open HavenUI.app  # or swift run

# Check if hostagent is running
ps aux | grep hostagent

# Quit HavenUI and verify hostagent stops
osascript -e 'tell application "HavenUI" to quit'
sleep 2
ps aux | grep hostagent  # should return nothing
```

### Viewing Logs

```bash
# HavenUI is using console output - run from terminal to see logs
swift run

# hostagent logs
tail -f ~/Library/Logs/Haven/hostagent.log
tail -f ~/Library/Logs/Haven/hostagent-error.log
```

## Related Documentation

- [HostAgent README](../hostagent/hostagent-readme.md) - hostagent service documentation
- [HostAgent Overview](../hostagent/index.md) - HostAgent architecture and API
- [Agents Guide](AGENTS.md) - System architecture and agent responsibilities
- [Local Development](../operations/local-dev.md) - Setting up Haven for development
