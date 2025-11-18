//
//  CollectorDetailView.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import SwiftUI

struct CollectorDetailView: View {
    let collector: CollectorInfo?
    let isRunning: Bool
    let lastRunStats: CollectorStateResponse?
    let jobProgress: JobProgress?
    let onRunNow: () -> Void
    let onRunWithOptions: () -> Void
    let onViewHistory: () -> Void
    let onCancel: (() -> Void)?
    let onReset: (() -> Void)?
    
    var body: some View {
        if let collector = collector {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header section
                    headerSection(collector: collector)
                    
                    Divider()
                    
                    // Status section
                    CollectorStatusView(
                        collector: collector,
                        isRunning: isRunning,
                        lastRunStats: lastRunStats
                    )
                    
                    Divider()
                    
                    // Quick actions
                    quickActionsSection
                }
                .padding()
            }
        } else {
            VStack {
                Text("No collector selected")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Select a collector from the sidebar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    @ViewBuilder
    private func headerSection(collector: CollectorInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(collector.displayName)
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text(collector.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // Status badge
                statusBadge(collector: collector)
            }
            
            HStack(spacing: 16) {
                if let lastRunTime = collector.lastRunTime {
                    Label(collector.relativeTimeString(), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                if collector.enabled {
                    Label("Enabled", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("Disabled", systemImage: "circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    @ViewBuilder
    private func statusBadge(collector: CollectorInfo) -> some View {
        let statusColor = getStatusColor(collector: collector)
        let statusText = getStatusText(collector: collector)
        
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            
            Text(statusText)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.1))
        .cornerRadius(8)
    }
    
    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.headline)
            
            if isRunning {
                // Show cancel button when running
                Button(action: {
                    onCancel?()
                }) {
                    Label("Cancel", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                
                // Progress bar section
                if let progress = jobProgress {
                    VStack(alignment: .leading, spacing: 12) {
                        // Progress bar (only show if we have total)
                        if let total = progress.total, total > 0 {
                            ProgressView(value: progress.overallProgress ?? 0.0)
                                .progressViewStyle(.linear)
                        }
                        
                        // Phase text
                        HStack {
                            Text(progress.currentPhase ?? "Processing...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                            
                        // Statistics section - show all stats prominently
                        VStack(alignment: .leading, spacing: 8) {
                            // Total records (from initial query) - always show when available
                                if let total = progress.total, total > 0 {
                                HStack {
                                    Text("Total Records:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(total)")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                        .monospacedDigit()
                                }
                                Divider()
                            }
                            
                            // Granular state tracking (Found, Queued, Enriched, Submitted)
                            if progress.found > 0 || progress.queued > 0 || progress.enriched > 0 || progress.submitted > 0 {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Processing States")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.secondary)
                                    
                                    HStack(spacing: 16) {
                                        // Found
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Found")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text("\(progress.found)")
                                                .font(.caption)
                                                .fontWeight(.semibold)
                                                .foregroundStyle(.blue)
                                                .monospacedDigit()
                                        }
                                        
                                        // Queued
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Queued")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text("\(progress.queued)")
                                                .font(.caption)
                                                .fontWeight(.semibold)
                                                .foregroundStyle(.orange)
                                                .monospacedDigit()
                                        }
                                        
                                        // Enriched
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Enriched")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text("\(progress.enriched)")
                                                .font(.caption)
                                                .fontWeight(.semibold)
                                                .foregroundStyle(.purple)
                                                .monospacedDigit()
                                        }
                                        
                                        // Submitted
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Submitted")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text("\(progress.submitted)")
                                            .font(.caption)
                                                .fontWeight(.semibold)
                                                .foregroundStyle(.green)
                                                .monospacedDigit()
                                        }
                                        
                                        Spacer()
                                        
                                        // Progress percentage (if we have total)
                                        if let total = progress.total, total > 0, let overallProgress = progress.overallProgress {
                                            VStack(alignment: .trailing, spacing: 2) {
                                                Text("Progress")
                                                    .font(.caption2)
                                            .foregroundStyle(.secondary)
                                                Text("\(Int(overallProgress * 100))%")
                                                    .font(.caption)
                                                    .fontWeight(.semibold)
                                                    .foregroundStyle(.primary)
                                                    .monospacedDigit()
                                            }
                                        }
                                    }
                                }
                                Divider()
                            }
                            
                            // Additional statistics (errors, skipped)
                            if progress.errors > 0 || progress.skipped > 0 {
                                HStack(spacing: 16) {
                                    // Errors
                                    if progress.errors > 0 {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Errors")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text("\(progress.errors)")
                                            .font(.caption)
                                                .fontWeight(.semibold)
                                                .foregroundStyle(.red)
                                            .monospacedDigit()
                                    }
                                    }
                                    
                                    // Skipped
                                    if progress.skipped > 0 {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Skipped")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text("\(progress.skipped)")
                                            .font(.caption)
                                                .fontWeight(.semibold)
                                                .foregroundStyle(.orange)
                                            .monospacedDigit()
                                        }
                                    }
                                    
                                    Spacer()
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(8)
                    }
                    .padding(.top, 8)
                } else {
                    // Fallback progress indicator when progress is not available
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Collector is running...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            } else {
                // Show run buttons when not running
                VStack(spacing: 12) {
                    // Show message if collector is disabled
                    if let collector = collector, !collector.enabled {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.orange)
                            Text(disabledMessage(for: collector))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }
                    
                    // Show last run stats when inactive
                    if let stats = lastRunStats, let progress = jobProgressFromLastRunStats(stats) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Last Run Statistics")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            
                            // Statistics section - same format as active run
                            VStack(alignment: .leading, spacing: 8) {
                                // Total records (from initial query) - always show when available
                                if let total = progress.total, total > 0 {
                                    HStack {
                                        Text("Total Records:")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(total)")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.primary)
                                            .monospacedDigit()
                                    }
                                    Divider()
                                }
                                
                                // Granular state tracking (Found, Queued, Enriched, Submitted)
                                if progress.found > 0 || progress.queued > 0 || progress.enriched > 0 || progress.submitted > 0 {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Processing States")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.secondary)
                                        
                                        HStack(spacing: 16) {
                                            // Found
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Found")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                Text("\(progress.found)")
                                                    .font(.caption)
                                                    .fontWeight(.semibold)
                                                    .foregroundStyle(.blue)
                                                    .monospacedDigit()
                                            }
                                            
                                            // Queued
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Queued")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                Text("\(progress.queued)")
                                                    .font(.caption)
                                                    .fontWeight(.semibold)
                                                    .foregroundStyle(.orange)
                                                    .monospacedDigit()
                                            }
                                            
                                            // Enriched
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Enriched")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                Text("\(progress.enriched)")
                                                    .font(.caption)
                                                    .fontWeight(.semibold)
                                                    .foregroundStyle(.purple)
                                                    .monospacedDigit()
                                            }
                                            
                                            // Submitted
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Submitted")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                Text("\(progress.submitted)")
                                                    .font(.caption)
                                                    .fontWeight(.semibold)
                                                    .foregroundStyle(.green)
                                                    .monospacedDigit()
                                            }
                                            
                                            Spacer()
                                            
                                            // Progress percentage (if we have total)
                                            if let total = progress.total, total > 0, let overallProgress = progress.overallProgress {
                                                VStack(alignment: .trailing, spacing: 2) {
                                                    Text("Progress")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                    Text("\(Int(overallProgress * 100))%")
                                                        .font(.caption)
                                                        .fontWeight(.semibold)
                                                        .foregroundStyle(.primary)
                                                        .monospacedDigit()
                                                }
                                            }
                                        }
                                    }
                                    Divider()
                                }
                                
                                // Additional statistics (errors, skipped)
                                if progress.errors > 0 || progress.skipped > 0 {
                                    HStack(spacing: 16) {
                                        // Errors
                                        if progress.errors > 0 {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Errors")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                Text("\(progress.errors)")
                                                    .font(.caption)
                                                    .fontWeight(.semibold)
                                                    .foregroundStyle(.red)
                                                    .monospacedDigit()
                                            }
                                        }
                                        
                                        // Skipped
                                        if progress.skipped > 0 {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Skipped")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                Text("\(progress.skipped)")
                                                    .font(.caption)
                                                    .fontWeight(.semibold)
                                                    .foregroundStyle(.orange)
                                                    .monospacedDigit()
                                            }
                                        }
                                        
                                        Spacer()
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                            .cornerRadius(8)
                        }
                        .padding(.bottom, 8)
                    }
                    
                    HStack(spacing: 12) {
                        Button(action: onRunNow) {
                            Label("Run Now", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(collector?.enabled == false)
                        
                        Button(action: onRunWithOptions) {
                            Label("Run with Options...", systemImage: "slider.horizontal.3")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(collector?.enabled == false)
                        
                        Button(action: onViewHistory) {
                            Label("View History", systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(collector?.enabled == false)
                    }
                    
                    // Reset button
                    if let onReset = onReset {
                        Button(action: onReset) {
                            Label("Reset Collector", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .disabled(collector?.enabled == false)
                    }
                }
            }
        }
    }
    
    private func getStatusColor(collector: CollectorInfo) -> Color {
        if isRunning {
            return .yellow
        }
        switch collector.lastRunStatus?.lowercased() {
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
    
    private func getStatusText(collector: CollectorInfo) -> String {
        if isRunning {
            return "Running..."
        }
        switch collector.lastRunStatus?.lowercased() {
        case "ok":
            return "Idle"
        case "error":
            return "Error"
        case "partial":
            return "Partial"
        default:
            return "Never Run"
        }
    }
    
    private func disabledMessage(for collector: CollectorInfo) -> String {
        switch collector.id {
        case "email_imap":
            return "No IMAP collector instances configured"
        case "contacts":
            return "No contacts collector instances configured"
        case "reminders":
            return "Reminders collector is disabled. Please enable it in Settings → General → Modules."
        case "localfs":
            return "No files collector instances configured"
        case "icloud_drive":
            return "No iCloud Drive collector instances configured"
        default:
            return "Collector is disabled"
        }
    }
    
    /// Convert lastRunStats from CollectorStateResponse to JobProgress for display
    private func jobProgressFromLastRunStats(_ stats: CollectorStateResponse) -> JobProgress? {
        guard let statsDict = stats.lastRunStats else { return nil }
        
        let scanned = getIntValue(from: statsDict, key: "scanned") ?? 0
        let matched = getIntValue(from: statsDict, key: "matched") ?? 0
        let submitted = getIntValue(from: statsDict, key: "submitted") ?? 0
        let skipped = getIntValue(from: statsDict, key: "skipped") ?? 0
        let errors = getIntValue(from: statsDict, key: "errors") ?? 0
        let total = getIntValue(from: statsDict, key: "total") ?? scanned > 0 ? scanned : nil
        let found = getIntValue(from: statsDict, key: "found") ?? scanned
        let queued = getIntValue(from: statsDict, key: "queued") ?? 0
        let enriched = getIntValue(from: statsDict, key: "enriched") ?? 0
        
        // Only return progress if we have meaningful data
        guard submitted > 0 || scanned > 0 || found > 0 else { return nil }
        
        return JobProgress(
            scanned: scanned,
            matched: matched,
            submitted: submitted,
            skipped: skipped,
            errors: errors,
            total: total,
            currentPhase: nil,
            phaseProgress: nil,
            found: found,
            queued: queued,
            enriched: enriched
        )
    }
    
    private func getIntValue(from dict: [String: AnyCodable]?, key: String) -> Int? {
        guard let dict = dict,
              let value = dict[key] else {
            return nil
        }
        switch value {
        case .int(let val):
            return val
        case .string(let str):
            return Int(str)
        default:
            return nil
        }
    }
}

