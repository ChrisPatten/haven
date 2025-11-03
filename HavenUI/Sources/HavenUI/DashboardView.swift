import SwiftUI
import AppKit

struct DashboardView: View {
    var appState: AppState
    var client: HostAgentClient
    let startAction: () async -> Void
    let stopAction: () async -> Void
    let runAllAction: () async -> Void
    
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "circle.fill")
                    .foregroundStyle(statusColor)
                    .font(.system(size: 12))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Haven Dashboard")
                        .font(.headline)
                    Text(appState.status.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button(action: { }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .help("Close")
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Service Status Section
                    ServiceStatusSection(appState: appState)
                    
                    Divider()
                    
                    // Health Indicators Section
                    if let health = appState.healthResponse {
                        HealthIndicatorsSection(modules: health.modules)
                        Divider()
                    }
                    
                    // Quick Actions Section
                    QuickActionsSection(
                        appState: appState,
                        startAction: startAction,
                        stopAction: stopAction,
                        runAllAction: runAllAction
                    )
                    
                    Divider()
                    
                    // Recent Activity Section
                    RecentActivitySection(activity: appState.recentActivity)
                    
                    // Error Banner
                    if let error = appState.errorMessage {
                        ErrorBannerView(message: error)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(.controlBackgroundColor))
    }
    
    private var statusColor: Color {
        switch appState.status {
        case .green:
            return .green
        case .yellow:
            return .yellow
        case .red:
            return .red
        }
    }
}

// MARK: - Service Status Section

struct ServiceStatusSection: View {
    var appState: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Service Status")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            if let health = appState.healthResponse {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Status")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(appState.processState == .running ? "Running" : "Stopped")
                            .font(.body)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Uptime")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formatUptime(health.uptimeSeconds))
                            .font(.body)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Version")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(health.version)
                            .font(.body)
                            .monospaced()
                    }
                    
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                Text("No health data available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func formatUptime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        
        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, secs)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, secs)
        } else {
            return String(format: "%ds", secs)
        }
    }
}

// MARK: - Health Indicators Section

struct HealthIndicatorsSection: View {
    var modules: [ModuleSummary]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Health Indicators")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            VStack(spacing: 6) {
                ForEach(modules, id: \.name) { module in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(module.enabled ? .green : .gray)
                            .frame(width: 8, height: 8)
                        
                        Text(module.name)
                            .font(.caption)
                        
                        Text(module.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        Text(module.enabled ? "Enabled" : "Disabled")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Quick Actions Section

struct QuickActionsSection: View {
    var appState: AppState
    let startAction: () async -> Void
    let stopAction: () async -> Void
    let runAllAction: () async -> Void
    
    @State private var isRunning = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Actions")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            HStack(spacing: 8) {
                Button(action: {
                    Task {
                        await startAction()
                    }
                }) {
                    Label("Start", systemImage: "play.fill")
                        .font(.caption)
                }
                .disabled(appState.status == .green || appState.isLoading())
                
                Button(action: {
                    Task {
                        await stopAction()
                    }
                }) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption)
                }
                .disabled(appState.status == .red || appState.isLoading())
                
                Divider()
                    .frame(height: 24)
                
                Button(action: {
                    Task {
                        isRunning = true
                        await runAllAction()
                        isRunning = false
                    }
                }) {
                    if isRunning || appState.isRunningAllCollectors {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.8, anchor: .center)
                            Text("Running...")
                                .font(.caption)
                        }
                    } else {
                        Label("Run All", systemImage: "play.circle.fill")
                            .font(.caption)
                    }
                }
                .disabled(appState.status != .green || appState.isLoading())
                
                Button(action: openLogs) {
                    Label("Logs", systemImage: "folder")
                        .font(.caption)
                }
                
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }
    
    private func openLogs() {
        let logsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Haven")
        NSWorkspace.shared.open(logsPath)
    }
}

// MARK: - Recent Activity Section

struct RecentActivitySection: View {
    var activity: [CollectorActivity]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Activity")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            if activity.isEmpty {
                Text("No collector runs yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 6) {
                    ForEach(activity) { item in
                        ActivityItemView(activity: item)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct ActivityItemView: View {
    var activity: CollectorActivity
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(activity.collector)
                            .font(.caption)
                            .fontWeight(.medium)
                        
                        Text(formatTime(activity.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        Text(activity.status)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(statusBackgroundColor)
                            .cornerRadius(3)
                    }
                    
                    HStack(spacing: 12) {
                        Label(String(activity.scanned), systemImage: "doc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        Label(String(activity.submitted), systemImage: "arrow.up")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
            }
            
            if !activity.errors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(activity.errors.prefix(1), id: \.self) { error in
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(4)
    }
    
    private var statusColor: Color {
        switch activity.status {
        case "ok":
            return .green
        case "error":
            return .red
        case "partial":
            return .yellow
        default:
            return .gray
        }
    }
    
    private var statusBackgroundColor: Color {
        switch activity.status {
        case "ok":
            return Color.green.opacity(0.1)
        case "error":
            return Color.red.opacity(0.1)
        case "partial":
            return Color.yellow.opacity(0.1)
        default:
            return Color.gray.opacity(0.1)
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - Error Banner

struct ErrorBannerView: View {
    var message: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            
            Text(message)
                .font(.caption)
                .lineLimit(2)
            
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(4)
    }
}

#Preview {
    DashboardView(
        appState: AppState(),
        client: HostAgentClient(),
        startAction: { },
        stopAction: { },
        runAllAction: { }
    )
}
