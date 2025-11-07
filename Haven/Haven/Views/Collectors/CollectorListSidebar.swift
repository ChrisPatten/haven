//
//  CollectorListSidebar.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import SwiftUI

struct CollectorListSidebar: View {
    @Binding var collectors: [CollectorInfo]
    @Binding var selectedCollectorId: String?
    let isCollectorRunning: (String) -> Bool
    let onRunAll: () -> Void
    let isLoading: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedCollectorId) {
                ForEach(collectorCategories) { category in
                    Section(category.name) {
                        ForEach(collectorsInCategory(category.id)) { collector in
                            CollectorSidebarRow(
                                collector: collector,
                                isRunning: isCollectorRunning(collector.id),
                                isSelected: selectedCollectorId == collector.id
                            )
                            .tag(collector.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            
            Divider()
            
            // Run All button
            Button(action: onRunAll) {
                HStack {
                    Label("Run All", systemImage: "play.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                            .padding(.leading, 4)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading || collectors.isEmpty || hasRunningCollectors)
            .padding()
        }
    }
    
    private var hasRunningCollectors: Bool {
        collectors.contains { isCollectorRunning($0.id) }
    }
    
    private struct CollectorCategory: Identifiable {
        let id: String
        let name: String
    }
    
    private var collectorCategories: [CollectorCategory] {
        [
            CollectorCategory(id: "messages", name: "Messages"),
            CollectorCategory(id: "email", name: "Email"),
            CollectorCategory(id: "files", name: "Files"),
            CollectorCategory(id: "contacts", name: "Contacts")
        ]
    }
    
    private func collectorsInCategory(_ categoryId: String) -> [CollectorInfo] {
        collectors.filter { collector in
            // Only show collectors that match the category
            guard collector.category == categoryId else { return false }
            
            // For IMAP, files, and contacts collectors (including instance-specific ones),
            // only show if they're enabled (configured)
            // iMessage should always be shown regardless of enabled state
            if collector.id == "email_imap" || collector.id.hasPrefix("email_imap:") {
                return collector.enabled
            }
            if collector.id == "localfs" || collector.id.hasPrefix("localfs:") {
                return collector.enabled
            }
            if collector.id == "contacts" || collector.id.hasPrefix("contacts:") {
                return collector.enabled
            }
            
            // Show all other collectors (including iMessage)
            return true
        }
        .sorted { $0.displayName < $1.displayName }
    }
}

struct CollectorSidebarRow: View {
    let collector: CollectorInfo
    let isRunning: Bool
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                
                if isRunning {
                    Circle()
                        .fill(statusColor.opacity(0.3))
                        .frame(width: 12, height: 12)
                        .blur(radius: 2)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isRunning)
                }
            }
            
            // Collector name
            VStack(alignment: .leading, spacing: 2) {
                Text(collector.displayName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                if let lastRunTime = collector.lastRunTime {
                    Text(relativeTimeString(from: lastRunTime))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Never run")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Enabled indicator
            if collector.enabled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
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
    
    private func relativeTimeString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

