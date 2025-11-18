//
//  CollectorStatusView.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import SwiftUI

struct CollectorStatusView: View {
    let collector: CollectorInfo
    let isRunning: Bool
    let lastRunStats: CollectorStateResponse?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status badge
            HStack(spacing: 12) {
                statusBadge
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusText)
                        .font(.headline)
                    
                    if let lastRunTime = collector.lastRunTime {
                        HStack(spacing: 4) {
                            Text("Last run: \(relativeTimeString(from: lastRunTime))")
                            if let stats = lastRunStats, let submitted = getIntValue(from: stats.lastRunStats, key: "submitted"), submitted > 0 {
                                Text("• \(submitted) submitted")
                                    .foregroundStyle(.green)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Never run")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // Running state or last run stats
            if isRunning {
                runningStateView
            } else if let stats = lastRunStats {
                lastRunStatsView(stats)
            }
        }
    }
    
    private var statusBadge: some View {
        ZStack {
            Circle()
                .fill(statusColor)
                .frame(width: 24, height: 24)
            
            if isRunning {
                Circle()
                    .fill(statusColor.opacity(0.3))
                    .frame(width: 32, height: 32)
                    .blur(radius: 2)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isRunning)
            }
        }
    }
    
    private var statusColor: Color {
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
    
    private var statusText: String {
        if isRunning {
            return "Running..."
        }
        switch collector.lastRunStatus?.lowercased() {
        case "ok":
            return "Idle"
        case "error":
            return "Error"
        case "partial":
            return "Partial Success"
        default:
            return "Never Run"
        }
    }
    
    private var runningStateView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Collector is running...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
    }
    
    private func lastRunStatsView(_ stats: CollectorStateResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let statsDict = stats.lastRunStats {
                // Primary stats: Found, Processed, Submitted
                HStack(spacing: 16) {
                    if let scanned = getIntValue(from: statsDict, key: "scanned") {
                        StatItem(label: "Found", value: "\(scanned)")
                    }
                    if let matched = getIntValue(from: statsDict, key: "matched") {
                        StatItem(label: "Processed", value: "\(matched)")
                    }
                    if let submitted = getIntValue(from: statsDict, key: "submitted") {
                        StatItem(label: "Submitted", value: "\(submitted)")
                    }
                }
                
                // Secondary stats: Errors (if any)
                if let errors = getIntValue(from: statsDict, key: "errors"), errors > 0 {
                    HStack(spacing: 16) {
                        StatItem(label: "Errors", value: "\(errors)", color: .red)
                        if let skipped = getIntValue(from: statsDict, key: "skipped"), skipped > 0 {
                            StatItem(label: "Skipped", value: "\(skipped)", color: .orange)
                        }
                    }
                    .padding(.top, 4)
                } else if let skipped = getIntValue(from: statsDict, key: "skipped"), skipped > 0 {
                    HStack(spacing: 16) {
                        StatItem(label: "Skipped", value: "\(skipped)", color: .orange)
                    }
                    .padding(.top, 4)
                }
            }
            
            if let error = collector.lastError, !error.isEmpty {
                Text("Error: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
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
    
    private func relativeTimeString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct StatItem: View {
    let label: String
    let value: String
    var color: Color = .primary
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
    }
}

