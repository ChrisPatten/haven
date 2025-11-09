## Combined Haven UI Implementation Prompt

### Identity & Theming
- Respect macOS appearance; use semantic system colors and materials as the base.
- Introduce `HavenColors/HavenGradients` helper that adapts for light/dark/high-contrast modes.
  - `primaryGradient`: #9AD99A → #00B8A9, reserved for primary/confirm states and subtle progress accents.
  - `backgroundLightGradient`: #D8EEE1 → #9BCFBF (use as accent mats, not full-surface repaint).
  - `backgroundDarkGradient`: #2A3B38 → #1B2422 (dark-mode accent panels only).
  - `accentGlow`: #EAF6FF for focus rings, subtle success glow, spinner halo.
  - Text: Light mode `#2E3B36`, dark mode `#EAF6FF`; secondary `#6E7C78`.
  - Neutral chrome: `#C2B8A2` with low opacity for dividers/tintless surfaces.
- Geometry: rounded corners, soft depth; only add custom shadows when native controls lack affordance.
- Visual identity takes cues from a sprouting plant—subtle leaf/seedling iconography in status, progress, empty states.

### Main Window Architecture
- Replace the current collectors-only window with a single primary document window using `NavigationSplitView`.
  - Sidebar (left) hosts top-level sections: Dashboard (default selection), Collectors, Permissions, Logs, Settings.
  - Sidebar must be resizable, state-restored (selection, width, expanded groups) and not collapsible; remove collapse toggle/button.
  - Default selection on launch: Dashboard entry showing existing dashboard content in the detail pane.
- Detail area swaps pages based on sidebar selection:
  - Dashboard: existing dashboard UI, relocated here.
  - Collectors: collectors overview/detail flow (per sections below).
  - Permissions: consolidated TCC/FDA guidance, statuses, deeplinks (respect guidelines).
  - Logs: streaming or on-demand log viewer with link to `~/Library/Logs/Haven/haven.log`.
  - Settings: read-only summary with shortcut to open full Settings window.
- Toolbar (native `Toolbar`):
  - Left: `ToggleSidebarButton()`.
  - Center: Title + subtitle (e.g., “Haven – Ready” with connection summary).
  - Right: high-frequency actions per section (Run All, Add Collector, Filter, SearchField). Use SF Symbols, brand gradient only on primary action.
  - Include a `SearchField` in the toolbar; support token filters scoped to the active section.

### Collector Management (sidebar “Collectors” section)
- Sidebar subsection lists collectors grouped by type; remember expanded/collapsed state.
- Add top-level “Add Collector” primary button (gradient) at top of collectors list.
  - Launch wizard: Step 1 choose type, Step 2 configure (fields identical to edit form).
  - “Save” commits, closes wizard, refreshes list; select the new collector.
- Collector detail pane redesign:
  - Remove top-right action buttons.
  - Header shows name, description, status badge with plant-inspired iconography, signed-in info (IMAP shows email address).
  - Replace existing status view with compact “History & Status” block showing total docs, most recent run doc count, last run timestamp.
  - Add inline “Edit” button (secondary style) to open same configuration UI prefilled; saving updates instance and refreshes detail.
  - Quick actions: Run, Run with Options, View History (stub until implemented), Cancel when running.
  - Bottom action row: `Reset Collector` (secondary/destructive, confirmation modal) + `Remove Collector` (destructive, confirmation modal). Both use modal sheets with friendly copy; dismiss returns to Dashboard if collector removed.
  - Display inline errors/warnings within detail view with actionable buttons (Retry/Fix), expandable technical details.
- Ensure state restoration for collector selection between launches.

### Collector Status Model
- Application states: Ready (default idle), Running (collector active, slow plant-inspired circular spinner with accent glow), Warning (subtle orange), Error (subtle red diamond/exclamation).
- Dashboard surface shows current global status with dismiss button next to the indicator; dismissal returns state to Ready.
- Collectors detail surfaces per-collector status and history (warnings, errors) with inline dismiss when appropriate.
- Status updates drive menubar icon tint/animation and toolbar subtitle.
- Persist last-known status; update based on collector runs and manual dismissals.

### Dashboard Integration
- Move existing dashboard widgets into detail pane for Dashboard section.
- Provide dismissal buttons for warnings/errors, use icons consistent with identity (leaf sprouts for success, gentle caution for warnings).
- Include recent activity, collector run summary, system health, quick action buttons.

### Permissions & Logs Sections
- Permissions: display TCC/FDA statuses with just-in-time prompts, reasons, and deeplinks. Provide “Why we need this” sheet before invoking system prompts.
- Logs: combine filesystem + watch status, quick link to open log file (button using `OpenPanel` or `NSWorkspace.open` to `~/Library/Logs/Haven/haven.log`). Provide filters/search.

### Menubar & Menus
- Keep `MenuBarExtra` with icon reflecting status (gradient spinner, etc). Primary click opens/focuses main window (per user requirement). Provide secondary click menu for quick status + “Run All Collectors”, “Open Settings”, “Open Logs” to satisfy design guide; align commands with keyboard shortcuts.
- Implement full macOS menu bar structure:
  - App, File, Edit, View, Window, Help groups with standard items and Haven-specific entries (`Preferences…`, `Run All Collectors`, `New Collector` on Cmd+N, `Compact Mode` toggle, etc.).
  - Use `CommandGroup` in SwiftUI to register shortcuts; ensure parity with contextual menus and menubar extra.

### Settings Window
- Use SwiftUI `Settings {}` scene for dedicated window; remove left navigation list.
- Present only General and Advanced sections, each as tab/page within Settings (align with design guide while honoring reduction).
- Include search field in Settings window toolbar to filter options.
- Layout: stacked sections (like enrichment detail) with local description and hover tooltips (longer descriptions). Provide optional collapsible subsections.
- Buttons: `Back` (secondary) and `Save` (primary gradient). Place per HIG (trailing).
- Remove gateway configuration.
- Logging section: show friendly summary, clickable link to log file (no input boxes).
- Combine File System + Watch settings into one section.
- Add Intent LLM settings (model selection, endpoint, auth, toggles); follow stacked layout.
- Use consistent SF Symbols; ensure accessibility labels and dynamic type.

### Controls & Components
- Rely on native SwiftUI/AppKit controls: `List`, `Table`, `OutlineGroup`, `DisclosureGroup`.
- Persist table column order/width, filter states, density preference (default medium; View menu toggle for Compact).
- Filters appear in toolbar popover or sidebar section, never blocking modal.
- Primary buttons use brand gradient; others use system styles with subtle tint.

### Typography & Spacing
- Use SF Pro text styles; optional SF Rounded for large headings (title).
  - Titles: 20–22 pt, semibold.
  - Section headers: 13 pt, uppercase small caps style.
  - Body: 14–15 pt regular; secondary 12–13 pt.
- Maintain 8-pt grid; 16–24 pt between related groups, 32 pt around major sections.
- Ensure text contrast meets accessibility guidelines in both modes.

### Motion & Feedback
- Animations: system spring 0.2–0.3s; on hover focus, scale 1.02 w/ slight shadow (use accent glow).
- Progress: native `ProgressView`, add subtle `accentGlow` aura on success completion events.
- Notifications: actionable Notification Center alerts (Open, Snooze); respect Focus, provide quiet hours toggle in Settings.

### Accessibility & State Restoration
- VoiceOver labels for custom components, focus order follows layout.
- Keyboard navigation throughout; ensure menu shortcuts for all major actions.
- Save/restore sidebar selection, expanded groups, filters, window size/position.
- Restore main window and Settings window on launch when previously open.

### Error Handling
- Inline, actionable; avoid modal alerts except destructive confirmations (reset/remove collector).
- Offer non-technical summary with expandable technical details logs/traces.
- Provide contextual help link (sprout-inspired icon) to docs.

### Iconography
- SF Symbols `.regular` weight; active tints use gradient or #00B8A9; otherwise default label color.
- Custom glyphs match SF Symbol weight/corner radius and align with plant motif.

### Implementation Notes
- Scene scaffold:
  - `@main` App uses `Settings { SettingsRootView() }`, `MenuBarExtra`, `NavigationSplitView`.
  - `SidebarView` enumerates sections; `ContentView` switches detail.
- Introduce environment-aware color/gradient utilities.
- Keep code modular: separate views for DashboardDetail, CollectorsDetail, PermissionsDetail, LogsDetail, SettingsSummary.
- Ensure data flows through `AppState`/`ViewModel`s with async updates; status state drives both UI and menubar.

### Testing & Verification
- Launch app → main window opens, Dashboard selected, sidebar sized as last session (or default).
- Add collector via wizard; confirm list refresh & selection.
- Edit collector, ensure prefilled values save + state persists.
- Remove & reset collector modals function; warn/confirm; dashboard fallback on removal.
- Status states change with runs; menubar icon animates; dashboard dismiss resets status.
- Menu bar commands & keyboard shortcuts trigger expected actions.
- Settings window opens on Cmd+, shows General/Advanced tabs, search filters options, Save/Back behave, Intent LLM section present, log link works.
- Logs & Permissions sections behave per guidelines.
- Accessibility: VoiceOver announces controls; keyboard navigation works; dynamic type scaling holds layout.
- State restoration: sidebar selection, window size, filters, density preferences persist across relaunch.
- Notifications respect quiet hours toggle and show actionable buttons.

Deliver a cohesive UI that feels native to macOS, embodies Haven’s plant-growth identity, and satisfies both the functional restructuring and stylistic requirements above.