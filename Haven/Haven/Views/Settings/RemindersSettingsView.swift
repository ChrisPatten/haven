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
    @Binding var config: RemindersInstanceConfig?
    var configManager: ConfigManager
    @Binding var errorMessage: String?
    
    @State private var selectedCalendarIds: Set<String> = []
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
                                
                                List(availableCalendars, id: \.calendarIdentifier, selection: $selectedCalendarIds) { calendar in
                                    HStack {
                                        // Calendar color indicator
                                        Circle()
                                            .fill(Color(cgColor: calendar.cgColor))
                                            .frame(width: 12, height: 12)
                                        
                                        Text(calendar.title)
                                            .font(.callout)
                                        
                                        Spacer()
                                        
                                        if selectedCalendarIds.contains(calendar.calendarIdentifier) {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        toggleCalendar(calendar.calendarIdentifier)
                                    }
                                }
                                .listStyle(.inset)
                                .frame(height: min(CGFloat(availableCalendars.count * 30), 300))
                            }
                        }
                    }
                    .padding()
                }
                
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .padding()
        }
        .onAppear {
            loadConfiguration()
            Task {
                await checkRemindersPermission()
                if remindersPermissionGranted {
                    await loadCalendars()
                }
            }
        }
        .onChange(of: selectedCalendarIds) { _, _ in updateConfiguration() }
        .onChange(of: remindersPermissionGranted) { _, newValue in
            if newValue {
                Task {
                    await loadCalendars()
                }
            }
        }
    }
    
    private func toggleCalendar(_ calendarId: String) {
        if selectedCalendarIds.contains(calendarId) {
            selectedCalendarIds.remove(calendarId)
        } else {
            selectedCalendarIds.insert(calendarId)
        }
    }
    
    private func loadConfiguration() {
        guard let config = config else {
            // Use defaults
            return
        }
        
        selectedCalendarIds = Set(config.selectedCalendarIds)
    }
    
    private func updateConfiguration() {
        config = RemindersInstanceConfig(selectedCalendarIds: Array(selectedCalendarIds))
    }
    
    private func checkRemindersPermission() async {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .reminder)
        
        await MainActor.run {
            if #available(macOS 14.0, *) {
                remindersPermissionGranted = status == .fullAccess
            } else {
                remindersPermissionGranted = status == .authorized
            }
        }
    }
    
    private func loadCalendars() async {
        isLoadingCalendars = true
        defer { isLoadingCalendars = false }
        
        let store = EKEventStore()
        let calendars = store.calendars(for: .reminder)
        
        await MainActor.run {
            availableCalendars = calendars.sorted { $0.title < $1.title }
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
                Label("Request Access", systemImage: "lock.open")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            
            Button(action: {
                openSystemSettings()
            }) {
                Label("Open Settings", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.bordered)
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
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .reminder)
        
        print("🔔 Reminders permission status: \(status.rawValue)")
        
        // Handle different authorization states
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess:
                // Already authorized
                print("🔔 Already has full access")
                remindersPermissionGranted = true
                onPermissionGranted()
                return
                
            case .notDetermined:
                // Request permission - this will show the native dialog
                print("🔔 Requesting full access to reminders...")
                do {
                    let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                        print("🔔 Calling requestFullAccessToReminders...")
                        store.requestFullAccessToReminders { granted, error in
                            print("🔔 requestFullAccessToReminders callback: granted=\(granted), error=\(error?.localizedDescription ?? "none")")
                            if let error = error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume(returning: granted)
                            }
                        }
                    }
                    remindersPermissionGranted = granted
                    
                    // Re-check status after request to ensure it's updated
                    let newStatus = EKEventStore.authorizationStatus(for: .reminder)
                    remindersPermissionGranted = (newStatus == .fullAccess)
                    
                    if remindersPermissionGranted {
                        onPermissionGranted()
                    }
                } catch {
                    // If request fails, check if we need to open System Settings
                    let currentStatus = EKEventStore.authorizationStatus(for: .reminder)
                    if currentStatus == .denied || currentStatus == .restricted {
                        openSystemSettings()
                    }
                    remindersPermissionGranted = false
                }
                
            case .denied, .restricted:
                // Permission was previously denied or restricted - must go to System Settings
                openSystemSettings()
                
            @unknown default:
                remindersPermissionGranted = false
            }
        } else {
            // Pre-macOS 14 handling
            switch status {
            case .authorized:
                remindersPermissionGranted = true
                onPermissionGranted()
                return
                
            case .notDetermined:
                do {
                    let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                        store.requestAccess(to: .reminder) { granted, error in
                            if let error = error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume(returning: granted)
                            }
                        }
                    }
                    remindersPermissionGranted = granted
                    
                    // Re-check status after request
                    let newStatus = EKEventStore.authorizationStatus(for: .reminder)
                    remindersPermissionGranted = (newStatus == .authorized)
                    
                    if remindersPermissionGranted {
                        onPermissionGranted()
                    }
                } catch {
                    let currentStatus = EKEventStore.authorizationStatus(for: .reminder)
                    if currentStatus == .denied || currentStatus == .restricted {
                        openSystemSettings()
                    }
                    remindersPermissionGranted = false
                }
                
            case .denied, .restricted:
                openSystemSettings()
                
            @unknown default:
                remindersPermissionGranted = false
            }
        }
    }
    
    private func openSystemSettings() {
        // Deep link to Reminders privacy settings pane
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        
        guard let url = URL(string: urlString) else {
            // Fallback: try to open System Settings app directly
            if let settingsURL = URL(string: "x-apple.systempreferences:") {
                NSWorkspace.shared.open(settingsURL)
            }
            return
        }
        
        // Open the deep link to Reminders privacy settings
        NSWorkspace.shared.open(url)
    }
}

