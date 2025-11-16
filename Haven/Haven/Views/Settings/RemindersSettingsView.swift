//
//  RemindersSettingsView.swift
//  Haven
//
//  Reminders collector configuration view
//

import SwiftUI
import EventKit

/// Reminders settings view
struct RemindersSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    
    @State private var availableCalendars: [EKCalendar] = []
    @State private var remindersPermissionGranted: Bool = false
    @State private var isLoadingCalendars: Bool = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Reminders permission banner
                if !remindersPermissionGranted {
                    RemindersPermissionBanner(
                        remindersPermissionGranted: $remindersPermissionGranted,
                        onPermissionGranted: {
                            Task {
                                await loadCalendars()
                            }
                        }
                    )
                }
                
                GroupBox("Reminders Configuration") {
                    VStack(alignment: .leading, spacing: 12) {
                        if isLoadingCalendars {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Loading reminder lists...")
                                    .foregroundStyle(.secondary)
                            }
                        } else if availableCalendars.isEmpty {
                            Text("No reminder lists available")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Select reminder lists to collect from:")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                Text("Leave all unchecked to collect from all lists")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                List(availableCalendars, id: \.calendarIdentifier, selection: selectedCalendarIdsBinding) { calendar in
                                    HStack {
                                        // Calendar color indicator
                                        Circle()
                                            .fill(Color(cgColor: calendar.cgColor))
                                            .frame(width: 12, height: 12)
                                        
                                        Text(calendar.title)
                                            .font(.callout)
                                        
                                        Spacer()
                                        
                                        if selectedCalendarIdsBinding.wrappedValue.contains(calendar.calendarIdentifier) {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        toggleCalendar(calendar.calendarIdentifier)
                                    }
                                }
                                .frame(height: 200)
                            }
                        }
                    }
                    .padding()
                }
                
                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .padding()
        }
        .task {
            await loadCalendars()
        }
    }
    
    // MARK: - Bindings
    
    private var selectedCalendarIdsBinding: Binding<Set<String>> {
        Binding(
            get: { Set(viewModel.remindersConfig?.selectedCalendarIds ?? []) },
            set: { newValue in
                viewModel.updateRemindersConfig { config in
                    config.selectedCalendarIds = Array(newValue)
                }
            }
        )
    }
    
    // MARK: - Helpers
    
    private func toggleCalendar(_ id: String) {
        var ids = Set(viewModel.remindersConfig?.selectedCalendarIds ?? [])
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        viewModel.updateRemindersConfig { config in
            config.selectedCalendarIds = Array(ids)
        }
    }
    
    private func loadCalendars() async {
        isLoadingCalendars = true
        defer { isLoadingCalendars = false }
        
        let eventStore = EKEventStore()
        
        do {
            let calendarsAccess = try await eventStore.requestWriteOnlyAccessToEvents()
            remindersPermissionGranted = calendarsAccess
            
            if calendarsAccess {
                availableCalendars = eventStore.calendars(for: .reminder)
            }
        } catch {
            remindersPermissionGranted = false
        }
    }
}

// MARK: - Reminders Permission Banner

struct RemindersPermissionBanner: View {
    @Binding var remindersPermissionGranted: Bool
    let onPermissionGranted: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Reminders Permission Required")
                    .font(.headline)
                    .foregroundStyle(.primary)
                
                Text("Haven needs access to your reminders to sync them. Click the button below to request access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(action: {
                Task { @MainActor in
                    await requestRemindersPermission()
                }
            }) {
                Label("Request Access", systemImage: "hand.raised.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            Color.orange.opacity(0.1)
        }
    }
    
    @MainActor
    private func requestRemindersPermission() async {
        let eventStore = EKEventStore()
        
        do {
            let access = try await eventStore.requestWriteOnlyAccessToEvents()
            remindersPermissionGranted = access
            
            if access {
                onPermissionGranted()
            }
        } catch {
            remindersPermissionGranted = false
        }
    }
}

#Preview {
    RemindersSettingsView(viewModel: SettingsViewModel(configManager: ConfigManager()))
}
