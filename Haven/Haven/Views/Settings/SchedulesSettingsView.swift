//
//  SchedulesSettingsView.swift
//  Haven
//
//  Automated collector run schedules management view
//

import SwiftUI

/// Schedules settings view for managing automated collector runs
struct SchedulesSettingsView: View {
    @Binding var config: CollectorSchedulesConfig?
    var configManager: ConfigManager
    @Binding var errorMessage: String?
    
    @State private var schedules: [CollectorSchedule] = []
    @State private var selectedSchedule: CollectorSchedule.ID?
    @State private var showingAddSheet = false
    @State private var showingEditSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button("Add Schedule") {
                    showingAddSheet = true
                }
                .buttonStyle(.borderedProminent)
                
                Button("Remove") {
                    removeSelectedSchedule()
                }
                .disabled(selectedSchedule == nil)
                
                Spacer()
            }
            .padding()
            
            Divider()
            
            // Info banner about schedule execution
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text("Note: Schedule execution engine is not yet implemented. Schedules can be created but will not run automatically.")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.1))
            
            Divider()
            
            // Table view
            if schedules.isEmpty {
                VStack {
                    Text("No schedules configured")
                        .foregroundColor(.secondary)
                    Text("Click 'Add Schedule' to configure automated collector runs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(schedules, selection: $selectedSchedule) {
                    TableColumn("Name") { schedule in
                        Text(schedule.name.isEmpty ? schedule.id : schedule.name)
                    }
                    TableColumn("Collector") { schedule in
                        Text(schedule.collectorInstanceId)
                    }
                    TableColumn("Schedule") { schedule in
                        Text(scheduleDescription(schedule))
                    }
                    TableColumn("Enabled") { schedule in
                        Toggle("", isOn: Binding(
                            get: { schedule.enabled },
                            set: { newValue in
                                if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
                                    schedules[index].enabled = newValue
                                    updateConfiguration()
                                }
                            }
                        ))
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            ScheduleEditSheet(
                schedule: nil,
                availableCollectors: getAvailableCollectors(),
                onSave: { schedule in
                    schedules.append(schedule)
                    updateConfiguration()
                }
            )
        }
        .sheet(isPresented: $showingEditSheet) {
            if let selectedId = selectedSchedule,
               let schedule = schedules.first(where: { $0.id == selectedId }) {
                ScheduleEditSheet(
                    schedule: schedule,
                    availableCollectors: getAvailableCollectors(),
                    onSave: { updatedSchedule in
                        if let index = schedules.firstIndex(where: { $0.id == updatedSchedule.id }) {
                            schedules[index] = updatedSchedule
                            updateConfiguration()
                        }
                    }
                )
            }
        }
        .onAppear {
            loadConfiguration()
        }
        .onChange(of: selectedSchedule) { _, newValue in
            // Only auto-open edit sheet if selected from table row click, not from pencil button
            // The pencil button sets showingEditSheet directly
        }
    }
    
    private func loadConfiguration() {
        guard let config = config else {
            schedules = []
            return
        }
        
        schedules = config.schedules
    }
    
    private func updateConfiguration() {
        config = CollectorSchedulesConfig(schedules: schedules)
    }
    
    private func removeSelectedSchedule() {
        guard let selectedId = selectedSchedule else { return }
        schedules.removeAll { $0.id == selectedId }
        selectedSchedule = nil
        updateConfiguration()
    }
    
    private func getAvailableCollectors() -> [String] {
        // TODO: Get actual collectors from configs
        // Should read from:
        // - Email instances: email:{instance.id}
        // - iMessage: imessage:default
        // - LocalFS instances: localfs:{instance.id}
        // - Contacts instances: contacts:{instance.id}
        // Backend implementation pending
        return []
    }
    
    private func scheduleDescription(_ schedule: CollectorSchedule) -> String {
        switch schedule.scheduleType {
        case .cron:
            return schedule.cronExpression ?? "No cron expression"
        case .interval:
            if let seconds = schedule.intervalSeconds {
                return "Every \(seconds) seconds"
            }
            return "No interval set"
        }
    }
}

/// Sheet for editing a schedule
struct ScheduleEditSheet: View {
    let schedule: CollectorSchedule?
    let availableCollectors: [String]
    let onSave: (CollectorSchedule) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var id: String = ""
    @State private var name: String = ""
    @State private var collectorInstanceId: String = ""
    @State private var enabled: Bool = true
    @State private var scheduleType: ScheduleType = .interval
    @State private var cronExpression: String = ""
    @State private var intervalSeconds: Int = 3600
    @State private var cronValidationError: String? = nil
    @State private var cronHumanReadable: String? = nil
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display Name", text: $name, prompt: Text("e.g., Daily Email Sync"))
                        .help("A friendly name for this schedule")
                    
                    Toggle("Enabled", isOn: $enabled)
                }
                
                Section {
                    TextField("Collector Instance ID", text: $collectorInstanceId, prompt: Text("email:personal-icloud"))
                        .help("Format: collector_type:instance_id (e.g., email:personal-icloud, imessage:default, localfs:documents)")
                } header: {
                    Text("Collector")
                } footer: {
                    Text("The collector to run on this schedule. Format: collector_type:instance_id. Collector discovery will be available in a future update.")
                }
                
                Section {
                    Picker("Schedule Type", selection: $scheduleType) {
                        Text("Interval").tag(ScheduleType.interval)
                        Text("Cron Expression").tag(ScheduleType.cron)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Schedule Type")
                }
                
                if scheduleType == .interval {
                    Section {
                        HStack {
                            Text("Interval")
                            Spacer()
                            TextField("", value: $intervalSeconds, format: .number)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                            Text("seconds")
                                .foregroundColor(.secondary)
                            Stepper("", value: $intervalSeconds, in: 60...86400, step: 60)
                                .labelsHidden()
                        }
                    } header: {
                        Text("Interval")
                    } footer: {
                        Text("Run the collector every \(intervalSeconds) seconds (minimum: 60)")
                    }
                } else {
                    Section {
                        TextField("Cron expression", text: $cronExpression, prompt: Text("0 2 * * *"))
                            .help("Standard cron format: minute hour day month weekday")
                            .onChange(of: cronExpression) { _, newValue in
                                validateCronExpression(newValue)
                            }
                        
                        if let humanReadable = cronHumanReadable {
                            HStack(spacing: 4) {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                                Text(humanReadable)
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                            .padding(.top, 4)
                        }
                        
                        if let error = cronValidationError {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                    .font(.caption)
                                Text(error)
                                    .foregroundColor(.red)
                                    .font(.caption)
                            }
                            .padding(.top, 4)
                        }
                    } header: {
                        Text("Cron Expression")
                    } footer: {
                        Text("Standard cron format: minute (0-59) hour (0-23) day (1-31) month (1-12) weekday (0-6, 0=Sunday)")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(schedule == nil ? "Add Schedule" : "Edit Schedule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let schedule = CollectorSchedule(
                            id: schedule?.id ?? UUID().uuidString,
                            name: name,
                            collectorInstanceId: collectorInstanceId,
                            enabled: enabled,
                            scheduleType: scheduleType,
                            cronExpression: scheduleType == .cron ? (cronExpression.isEmpty ? nil : cronExpression) : nil,
                            intervalSeconds: scheduleType == .interval ? intervalSeconds : nil
                        )
                        onSave(schedule)
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 600, height: 500)
        .onAppear {
            if let schedule = schedule {
                id = schedule.id
                name = schedule.name
                collectorInstanceId = schedule.collectorInstanceId
                enabled = schedule.enabled
                scheduleType = schedule.scheduleType
                cronExpression = schedule.cronExpression ?? ""
                intervalSeconds = schedule.intervalSeconds ?? 3600
                if scheduleType == .cron && !cronExpression.isEmpty {
                    validateCronExpression(cronExpression)
                }
            } else {
                id = UUID().uuidString
            }
        }
    }
    
    private func validateCronExpression(_ expression: String) {
        cronValidationError = nil
        cronHumanReadable = nil
        
        if expression.isEmpty {
            return
        }
        
        let parts = expression.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        
        guard parts.count == 5 else {
            cronValidationError = "Cron expression must have 5 fields: minute hour day month weekday"
            return
        }
        
        // Basic validation - check if fields are valid
        let minute = parts[0]
        let hour = parts[1]
        let day = parts[2]
        let month = parts[3]
        let weekday = parts[4]
        
        // Simple validation - can be enhanced
        if !isValidCronField(minute, range: 0...59) {
            cronValidationError = "Invalid minute field (0-59)"
            return
        }
        if !isValidCronField(hour, range: 0...23) {
            cronValidationError = "Invalid hour field (0-23)"
            return
        }
        if !isValidCronField(day, range: 1...31) {
            cronValidationError = "Invalid day field (1-31)"
            return
        }
        if !isValidCronField(month, range: 1...12) {
            cronValidationError = "Invalid month field (1-12)"
            return
        }
        if !isValidCronField(weekday, range: 0...6) {
            cronValidationError = "Invalid weekday field (0-6, where 0=Sunday)"
            return
        }
        
        // Generate human-readable description
        cronHumanReadable = formatCronExpression(parts)
    }
    
    private func isValidCronField(_ field: String, range: ClosedRange<Int>) -> Bool {
        if field == "*" {
            return true
        }
        if let value = Int(field) {
            return range.contains(value)
        }
        // Handle ranges, lists, and steps (basic check)
        if field.contains("/") || field.contains("-") || field.contains(",") {
            return true  // Accept for now, full validation would be more complex
        }
        return false
    }
    
    private func formatCronExpression(_ parts: [String]) -> String {
        let minute = parts[0]
        let hour = parts[1]
        let day = parts[2]
        let month = parts[3]
        let weekday = parts[4]
        
        var description = "Runs "
        
        if minute == "*" && hour == "*" && day == "*" && month == "*" && weekday == "*" {
            return "Runs every minute"
        }
        
        // Format time
        if hour != "*" && minute != "*" {
            let hourInt = Int(hour) ?? 0
            let minuteInt = Int(minute) ?? 0
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            if let date = Calendar.current.date(bySettingHour: hourInt, minute: minuteInt, second: 0, of: Date()) {
                description += "at \(formatter.string(from: date))"
            } else {
                description += "at \(hour):\(minute)"
            }
        } else if hour != "*" {
            description += "at hour \(hour)"
        } else {
            description += "every hour"
        }
        
        // Format day
        if day != "*" {
            description += " on day \(day)"
        }
        
        // Format month
        if month != "*" {
            let monthNames = ["", "January", "February", "March", "April", "May", "June",
                             "July", "August", "September", "October", "November", "December"]
            if let monthInt = Int(month), monthInt >= 1 && monthInt <= 12 {
                description += " in \(monthNames[monthInt])"
            } else {
                description += " in month \(month)"
            }
        }
        
        // Format weekday
        if weekday != "*" {
            let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            if let weekdayInt = Int(weekday), weekdayInt >= 0 && weekdayInt <= 6 {
                description += " on \(weekdays[weekdayInt])"
            } else {
                description += " on weekday \(weekday)"
            }
        }
        
        return description
    }
}

