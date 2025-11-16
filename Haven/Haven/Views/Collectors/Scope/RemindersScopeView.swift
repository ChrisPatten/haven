//
//  RemindersScopeView.swift
//  Haven
//
//  Reminders collector scope configuration view
//

import SwiftUI
import EventKit

struct RemindersScopeView: View {
    @Binding var scopeData: [String: AnyCodable]
    let hostAgentController: HostAgentController?
    
    @State private var selectedCalendarIds: Set<String> = []
    @State private var availableCalendars: [EKCalendar] = []
    @State private var isLoadingCalendars: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reminder Lists")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                Text("Select which reminder lists to collect from. Leave all unchecked to collect from all lists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            if isLoadingCalendars {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading reminder lists...")
                        .foregroundStyle(.secondary)
                }
            } else if availableCalendars.isEmpty {
                Text("No reminder lists available. Please grant Reminders access in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
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
        .onAppear {
            loadScopeData()
            Task {
                await loadCalendars()
            }
        }
        .onChange(of: selectedCalendarIds) { _, _ in updateScope() }
    }
    
    private func toggleCalendar(_ calendarId: String) {
        if selectedCalendarIds.contains(calendarId) {
            selectedCalendarIds.remove(calendarId)
        } else {
            selectedCalendarIds.insert(calendarId)
        }
    }
    
    private func loadScopeData() {
        // Load selected calendar IDs from scope data
        if let calendarIdsValue = scopeData["calendar_ids"],
           case .string(let idsString) = calendarIdsValue {
            // Parse comma-separated string
            let ids = idsString.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            selectedCalendarIds = Set(ids)
        } else if let calendarIdsArray = scopeData["calendar_ids"] {
            // Try to parse as array (if stored differently)
            // This is a fallback - we'll store as comma-separated string
        }
    }
    
    private func updateScope() {
        // Store selected calendar IDs as comma-separated string in scope
        let idsArray = Array(selectedCalendarIds)
        if idsArray.isEmpty {
            // Empty means collect from all calendars
            scopeData["calendar_ids"] = .string("")
        } else {
            scopeData["calendar_ids"] = .string(idsArray.joined(separator: ","))
        }
    }
    
    private func loadCalendars() async {
        isLoadingCalendars = true
        defer { isLoadingCalendars = false }
        
        let store = EKEventStore()
        
        // Check authorization
        let status = EKEventStore.authorizationStatus(for: .reminder)
        let isAuthorized: Bool
        if #available(macOS 14.0, *) {
            isAuthorized = status == .fullAccess
        } else {
            isAuthorized = status == .authorized
        }
        
        guard isAuthorized else {
            await MainActor.run {
                availableCalendars = []
            }
            return
        }
        
        let calendars = store.calendars(for: .reminder)
        
        await MainActor.run {
            availableCalendars = calendars.sorted { $0.title < $1.title }
        }
    }
}

