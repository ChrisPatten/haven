# Settings Management Architecture

## Problem: Race Conditions

The current settings system has multiple race conditions because:

1. **Multiple State Sources**: Views maintain their own `@State` variables that duplicate config data
2. **Manual Syncing**: Views manually sync between `@State` and `@Binding` config objects using `.onAppear`, `.onChange`, and `.task(id:)`
3. **Lifecycle Race Conditions**: SwiftUI's reactive system fires multiple times during initialization, causing:
   - `.task(id:)` firing before `.onAppear` completes
   - `updateConfiguration()` running with default values before `loadConfiguration()` finishes
   - Settings being overwritten with empty/default values

## Solution: ViewModel Pattern

The new `SettingsViewModel` provides:

### Single Source of Truth
- All config state lives in `@Published` properties on the ViewModel
- Views bind directly to ViewModel properties
- No duplicate state in views

### Clear Data Flow
```
Disk (plist) → ConfigManager → SettingsViewModel → Views
Views → SettingsViewModel → ConfigManager → Disk (plist)
```

### No Manual Syncing
- Views use computed `Binding` properties that directly update ViewModel
- SwiftUI automatically handles reactivity
- No `.onAppear`, `.onChange`, or `.task(id:)` needed for syncing

### Benefits

1. **No Race Conditions**: Config is loaded once into ViewModel, then views bind to it
2. **Simpler Views**: Views only handle UI, not state management
3. **Type Safety**: Direct binding to config properties
4. **Testability**: ViewModel can be tested independently
5. **Maintainability**: Clear separation of concerns

## Migration Guide

### Step 1: Update SettingsWindow

```swift
struct SettingsWindow: View {
    @StateObject private var viewModel = SettingsViewModel(configManager: ConfigManager())
    @State private var selectedSection: SettingsSection = .general
    
    var body: some View {
        NavigationSplitView {
            // ... sidebar ...
        } detail: {
            detailView(for: selectedSection)
        }
        .task {
            // Load once when window appears
            await viewModel.loadAllConfigurations()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    Task {
                        await viewModel.saveAllConfigurations()
                    }
                }
                .disabled(viewModel.isSaving || viewModel.isLoading)
            }
        }
    }
    
    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView(viewModel: viewModel)
        // ... other sections ...
        }
    }
}
```

### Step 2: Refactor Settings Views

**Before (Current Pattern - Race Conditions):**
```swift
struct GeneralSettingsView: View {
    @Binding var config: SystemConfig?
    @State private var authHeader: String = ""  // Duplicate state!
    @State private var authSecret: String = ""  // Duplicate state!
    
    var body: some View {
        TextField("", text: $authHeader)  // Manual syncing needed
            .onAppear { loadConfiguration() }  // Race condition!
            .onChange(of: config) { loadConfiguration() }  // Race condition!
            .task(id: combinedState) { updateConfiguration() }  // Race condition!
    }
}
```

**After (ViewModel Pattern - No Race Conditions):**
```swift
struct GeneralSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    
    var body: some View {
        TextField("", text: authHeaderBinding)  // Direct binding, no syncing!
        // NO .onAppear, NO .onChange, NO .task(id:) needed!
    }
    
    private var authHeaderBinding: Binding<String> {
        Binding(
            get: { viewModel.systemConfig?.service.auth.header ?? "" },
            set: { newValue in
                viewModel.updateSystemConfig { config in
                    config.service.auth.header = newValue
                }
            }
        )
    }
}
```

### Step 3: Benefits Realized

- ✅ No race conditions - config loaded once, then bound
- ✅ No manual syncing - SwiftUI handles reactivity
- ✅ Simpler code - views only handle UI
- ✅ Type safe - direct access to config properties
- ✅ Testable - ViewModel can be unit tested

## Implementation Status

- [x] `SettingsViewModel` created
- [ ] `SettingsWindow` updated to use ViewModel
- [ ] `GeneralSettingsView` refactored
- [ ] Other settings views refactored
- [ ] Remove old pattern code

