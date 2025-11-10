# Reminders Collector

The Reminders collector syncs macOS Reminders.app data into Haven for search and analysis.

## Overview

The Reminders collector:
- Reads reminders from macOS Reminders.app via EventKit framework
- Extracts reminder content, due dates, completion status, and metadata
- Tracks changes for incremental sync
- Supports selecting specific reminder lists to collect
- Always skips enrichment (no images or attachments)

## Prerequisites

- macOS with Reminders.app
- Reminders permission (Full Access for macOS 14+)
- Gateway API running and accessible

## Using Haven.app (Recommended)

Haven.app provides the easiest way to run the Reminders collector:

1. **Launch Haven.app**

2. **Grant Permissions:**
   - System Settings → Privacy & Security → Reminders
   - Enable "Full Access" for Haven.app (macOS 14+)
   - Or enable standard access for older macOS versions
   - Restart Haven.app if already running

3. **Configure Collector:**
   - Open Settings (`⌘,`)
   - Navigate to Reminders Collector
   - Configure options:
     - Enable/disable collector
     - Select which reminder lists to collect from
     - All lists are shown by default; uncheck lists you don't want to sync

4. **Run Collector:**
   - Open Collectors window (`⌘2`)
   - Select Reminders collector
   - Click "Run" or use menu "Run All Collectors"

5. **Monitor Progress:**
   - View Dashboard (`⌘1`) for activity log
   - Check reminders processed count
   - Review any errors

## How It Works

### Data Extraction

1. **EventKit Access:**
   - Uses macOS EventKit framework to access Reminders
   - Requests appropriate permissions based on macOS version
   - macOS 14+ requires "Full Access" for change tracking

2. **Reminder Processing:**
   - Fetches reminders from selected calendars/lists
   - Extracts reminder content (title, notes)
   - Captures metadata:
     - Due dates and completion status
     - Priority levels
     - Alarms/notifications
     - Calendar/list membership
     - Creation and modification timestamps

3. **Change Tracking:**
   - Uses EventKit change notifications for incremental sync
   - Tracks last modification date per reminder
   - Only processes new or changed reminders on subsequent runs

4. **Ingestion:**
   - Converts reminders to document format
   - Submits to Gateway API via `DocumentSubmitter`
   - Gateway forwards to Catalog for persistence
   - Catalog creates documents and chunks
   - Embedding worker processes chunks for search

### List Selection

The collector supports selecting specific reminder lists:

- **All Lists:** By default, all available lists are selected
- **Selective Collection:** Uncheck lists you don't want to sync
- **Dynamic Lists:** Lists are refreshed when permissions are granted
- **List Metadata:** Each reminder includes its parent list/calendar name

### Incremental Sync

The collector tracks changes for efficient incremental sync:

- **State File:** `~/Library/Application Support/Haven/State/reminders_sync_state.json`
  - Tracks last modification date per reminder
  - Enables incremental sync (only processes changed reminders)
  - Automatically updated after each run

- **Change Notifications:**
  - Subscribes to `EKEventStoreChangedNotification`
  - Detects when reminders are added, modified, or deleted
  - Triggers incremental sync on next run

## Configuration

### Haven.app Configuration

Configure via Settings (`⌘,`) → Reminders Collector:

```yaml
collectors:
  reminders:
    enabled: true
    selected_calendar_identifiers:
      - "70E46C66-83A6-48F5-BBC9-4CEA9726760E"  # List UUID
      - "8FEC24A7-145D-47C0-8F0E-2D54CDBFCBD5"  # Another list UUID
```

**List Selection:**
- Lists are displayed with checkboxes in Settings
- Only checked lists will be collected
- List identifiers are UUIDs from EventKit

**Enrichment:**
The Reminders collector always skips enrichment (OCR, face detection, entity extraction, captioning) as reminders don't require these processing steps. This is automatically configured and cannot be changed.

## State Management

### State File

State is tracked in `~/Library/Application Support/Haven/State/reminders_sync_state.json`:

```json
{
  "70E46C66-83A6-48F5-BBC9-4CEA9726760E": "2025-11-10T14:42:08Z",
  "8FEC24A7-145D-47C0-8F0E-2D54CDBFCBD5": "2025-11-10T14:42:07Z"
}
```

The state file maps reminder identifiers (UUIDs) to their last modification dates.

### Resetting State

To force full re-sync:

```bash
# Remove state file
rm ~/Library/Application\ Support/Haven/State/reminders_sync_state.json

# Run collector (will process all reminders)
# In Haven.app: Collectors → Reminders → Run
```

**Warning:** This will re-process all reminders. Use with caution.

### State File Location

State files are stored in the centralized State directory:
- **Location:** `~/Library/Application Support/Haven/State/`
- **File:** `reminders_sync_state.json`
- **Purpose:** Tracks incremental sync state for efficient updates

This follows the new centralized state file management pattern used by all collectors.

## Reminder Data Structure

Each reminder is ingested as a document with:

- **Content:** Reminder title and notes (combined text)
- **Metadata:**
  - `reminder.calendar`: Name of the list/calendar
  - `reminder.priority`: Priority level (0-9)
  - `reminder.has_alarms`: Whether reminder has alarms
  - `reminder.alarms`: Array of alarm dates (if any)
- **Timestamps:**
  - `content_created_at`: When reminder was created
  - `content_modified_at`: Last modification time
  - `content_timestamp`: Used for search (modified time)
- **Due Dates:**
  - `has_due_date`: Whether reminder has a due date
  - `due_date`: Due date (if set)
- **Completion:**
  - `is_completed`: Completion status
  - `completed_at`: Completion timestamp (if completed)

## Troubleshooting

### Permission Issues

**Error:** Cannot access Reminders

**Solution:**
1. System Settings → Privacy & Security → Reminders
2. Enable "Full Access" for Haven.app (macOS 14+)
3. Or enable standard access for older macOS versions
4. Restart Haven.app

**macOS 14+ Note:** Full Access is required for change tracking. Without it, the collector can still read reminders but won't detect changes efficiently.

### No Reminders Appearing

**Issue:** Reminders not being collected

**Solutions:**
- Check that Reminders permission is granted
- Verify lists are selected in Settings
- Check that reminders exist in selected lists
- Review collector logs for errors
- Ensure Gateway is accessible

### Duplicate Reminders

**Issue:** Same reminder ingested multiple times

**Solution:**
- Check state file is being updated
- Verify incremental sync is working
- Check for multiple collector instances running
- Review Gateway idempotency logs

### Missing Lists

**Issue:** Some reminder lists not appearing in Settings

**Solutions:**
- Ensure Reminders permission is granted
- Refresh lists by clicking "Request Access" if needed
- Check that lists exist in Reminders.app
- Restart Haven.app to refresh list discovery

## Performance Considerations

### Large Reminder Lists

For large reminder lists (1000+ reminders):
- Incremental sync processes only changed reminders
- Initial sync may take longer but subsequent runs are fast
- Batch processing handles large volumes efficiently

### Change Tracking

- **Incremental Sync:** Fast, only processes changes
- **Full Sync:** Slower, processes all reminders
- Use incremental sync for regular syncs
- Use full sync after major changes (reset state file)

### List Selection

- **All Lists:** Processes all reminders (slower)
- **Selected Lists:** Only processes selected lists (faster)
- Select only lists you need for better performance

## Related Documentation

- [Configuration Reference](../reference/configuration.md) - Environment variables
- [Haven.app Guide](../havenui.md) - App usage
- [Functional Guide](../reference/functional_guide.md) - Ingestion workflows
- [Technical Reference](../reference/technical_reference.md) - Architecture details


