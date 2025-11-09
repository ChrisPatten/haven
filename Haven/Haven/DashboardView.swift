//
//  DashboardView.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import SwiftUI
import AppKit
import Combine

struct DashboardView: View {
    var appState: AppState
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
                
                if appState.errorMessage != nil {
                    Button("Dismiss Issues") {
                        appState.clearError()
                    }
                    .buttonStyle(HavenSecondaryButtonStyle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Service Status Section
                    ServiceStatusSection(appState: appState)
                    
                    Divider()
                    
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

                    Divider()

                    // Live Logs Section
                    LiveLogsSection()

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

// MARK: - Live Logs Section

struct LiveLogsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Logs")
                .font(.subheadline)
                .fontWeight(.semibold)

            TabView {
                LogViewerView(logFileName: "hostagent.log", title: "HostAgent Output")
                    .tabItem {
                        Label("Output", systemImage: "terminal")
                    }

                LogViewerView(logFileName: "hostagent-error.log", title: "HostAgent Errors")
                    .tabItem {
                        Label("Errors", systemImage: "exclamationmark.triangle")
                    }
            }
            .frame(height: 250)
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
            
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Status")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(appState.processState == .running ? "Running" : "Stopped")
                        .font(.body)
                }
                
                Spacer()
            }
            .padding(.vertical, 8)
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

// MARK: - Log Viewer

@MainActor
final class LogViewerModel: ObservableObject {
    @Published var logContent: String = "Loading logs..."
    @Published var isTailing: Bool = false

    private var logFileURL: URL
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var pollingTimer: Timer?
    private var lastFileSize: UInt64 = 0

    init(logFileName: String) {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Haven")
        logFileURL = logsDir.appendingPathComponent(logFileName)

        // Load initial content asynchronously to avoid blocking UI
        Task { @MainActor in
            await loadInitialContent()
            startTailingOrPolling()
        }
    }

    private func loadInitialContent() async {
        // Run file I/O on background thread to avoid blocking main thread
        // For large log files, only load the last portion to avoid memory issues
        let result = Task.detached { [logFileURL] in
            do {
                let fileSize = (try? logFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let maxBytesToRead = 100_000  // Only read last ~100KB
                
                if fileSize > maxBytesToRead {
                    // For large files, read only the tail
                    if let fileHandle = try? FileHandle(forReadingFrom: logFileURL) {
                        fileHandle.seek(toFileOffset: UInt64(fileSize - maxBytesToRead))
                        let data = fileHandle.readDataToEndOfFile()
                        try? fileHandle.close()
                        
                        if let content = String(data: data, encoding: .utf8) {
                            // Find first newline to avoid partial line
                            let firstNewline = content.firstIndex(of: "\n") ?? content.startIndex
                            let tailContent = String(content[firstNewline...])
                            return ("... (showing last \(maxBytesToRead / 1000)KB)\n" + tailContent, UInt64(fileSize))
                        }
                    }
                }
                
                // For small files or if tail read failed, read entire file
                let content = try String(contentsOf: logFileURL, encoding: .utf8)
                return (content.isEmpty ? "No logs yet..." : content, UInt64(fileSize))
            } catch {
                return ("Log file not found or empty", UInt64(0))
            }
        }
        
        let content = await result.value
        
        // Update UI on main thread
        logContent = content.0
        lastFileSize = content.1
    }

    private func startTailingOrPolling() {
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            startTailing()
        } else {
            startPolling()
        }
    }

    private func startTailing() {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else {
            startPolling()
            return
        }

        do {
            fileHandle = try FileHandle(forReadingFrom: logFileURL)
            fileHandle?.seekToEndOfFile()
            lastFileSize = UInt64((try? logFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

            source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileHandle!.fileDescriptor,
                eventMask: .extend,
                queue: DispatchQueue.main
            )

            source?.setEventHandler { [weak self] in
                guard let self = self else { return }
                self.readNewContent()
            }

            source?.resume()
            isTailing = true
            pollingTimer?.invalidate()
            pollingTimer = nil
        } catch {
            print("Failed to start log tailing: \(error)")
            startPolling()
        }
    }

    private func startPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            Task { @MainActor in
                do {
                    let currentSize = try self.logFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

                    if currentSize > Int(self.lastFileSize) {
                        // File has grown, read the new content
                        if let fileHandle = try? FileHandle(forReadingFrom: self.logFileURL) {
                            fileHandle.seek(toFileOffset: self.lastFileSize)
                            let data = fileHandle.readDataToEndOfFile()
                            try? fileHandle.close()

                            if let newContent = String(data: data, encoding: .utf8), !newContent.isEmpty {
                                if self.logContent == "No logs yet..." || self.logContent == "Log file not found or empty" {
                                    self.logContent = newContent
                                } else {
                                    self.logContent += newContent
                                }
                            }
                            self.lastFileSize = UInt64(currentSize)
                        }
                    }

                    // If file now exists and we're not tailing, try to start tailing
                    if !self.isTailing && FileManager.default.fileExists(atPath: self.logFileURL.path) {
                        self.startTailing()
                    }
                } catch {
                    // File might not exist yet, continue polling
                }
            }
        }
    }

    private func readNewContent() {
        guard let fileHandle = fileHandle else { return }

        let data = fileHandle.readDataToEndOfFile()
        if let newContent = String(data: data, encoding: .utf8), !newContent.isEmpty {
            if logContent == "No logs yet..." || logContent == "Log file not found or empty" {
                logContent = newContent
            } else {
                logContent += newContent
            }
        }
    }

    @MainActor
    func refreshContent() {
        Task {
            await loadInitialContent()
            if isTailing {
                source?.cancel()
                startTailingOrPolling()
            }
        }
    }

    deinit {
        source?.cancel()
        pollingTimer?.invalidate()
        try? fileHandle?.close()
    }
}

struct LogViewerView: View {
    @StateObject private var logModel: LogViewerModel
    let title: String

    init(logFileName: String, title: String) {
        _logModel = StateObject(wrappedValue: LogViewerModel(logFileName: logFileName))
        self.title = title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()

                if logModel.isTailing {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("Live")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                    Text("Waiting")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Button(action: {
                    logModel.refreshContent()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .help("Refresh log content")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(logModel.logContent)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("logContent")

                    // Invisible anchor at the bottom for scrolling
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .frame(height: 200)
                .background(Color(.textBackgroundColor).opacity(0.5))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(.separatorColor), lineWidth: 1)
                )
                .onChange(of: logModel.logContent) {
                    // Scroll to bottom when content changes
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    // Initial scroll to bottom
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}
