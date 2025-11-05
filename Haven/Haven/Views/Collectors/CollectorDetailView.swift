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
    let onRunNow: () -> Void
    let onRunWithOptions: () -> Void
    let onViewHistory: () -> Void
    
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
            
            HStack(spacing: 12) {
                Button(action: onRunNow) {
                    Label("Run Now", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
                
                Button(action: onRunWithOptions) {
                    Label("Run with Options...", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isRunning)
                
                Button(action: onViewHistory) {
                    Label("View History", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            
            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Collector is running...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
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
}

