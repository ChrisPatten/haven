//
//  MenuContent.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import SwiftUI
import AppKit

struct MenuContent: View {
    var appState: AppState
    let openDashboard: () -> Void
    let openCollectors: () -> Void
    let startAction: () async -> Void
    let stopAction: () async -> Void
    let runAllAction: () async -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Status Section
            HStack {
                Label(appState.status.description, systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
                    .font(.system(size: 7))
            }
            .padding(8)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(4)

            Divider()

            // Dashboard Button
            Button(action: openDashboard) {
                Label("Dashboard", systemImage: "rectangle.grid.2x2")
            }
            
            // Collectors Button
            Button(action: { openCollectors() }) {
                Label("Collectors", systemImage: "list.bullet")
            }
            
            Divider()
            
            // Start/Stop Controls
            HStack(spacing: 12) {
                Button(action: {
                    Task {
                        await startAction()
                    }
                }) {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(appState.status == .green || appState.isLoading())
                
                Button(action: {
                    Task {
                        await stopAction()
                    }
                }) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(appState.status == .red || appState.isLoading())
            }
            .padding(4)
            
            Divider()
            
            // Run All Button
            Button(action: {
                Task {
                    await runAllAction()
                }
            }) {
                if appState.isRunningAllCollectors {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7, anchor: .center)
                        Label("Running...", systemImage: "play.circle.fill")
                    }
                } else {
                    Label("Run All Collectors", systemImage: "play.circle.fill")
                }
            }
            .disabled(appState.status != .green || appState.isLoading())
            
            Divider()
            
            // Error Display
            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(4)
            }
            
            Divider()
            
            // Quit
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Label("Quit", systemImage: "xmark")
            }
        }
        .padding(8)
        .frame(minWidth: 250)
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

