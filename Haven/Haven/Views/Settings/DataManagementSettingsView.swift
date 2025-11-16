//
//  DataManagementSettingsView.swift
//  Haven
//
//  Data Management settings view
//  Provides controls for clearing collector state and debug files
//

import SwiftUI

/// Data Management settings view for clearing state files
struct DataManagementSettingsView: View {
    @Binding var errorMessage: String?
    
    @State private var showingClearConfirmation = false
    @State private var isClearing = false
    @State private var clearResult: ClearResult?
    
    private let stateManager = StateManager()
    
    private struct ClearResult {
        let clearedFiles: [String]
        let errors: [String]
        let clearedCount: Int
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                dataManagementSection
                
                if let result = clearResult {
                    clearResultView(result)
                }
                
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .padding()
        }
        .confirmationDialog(
            "Clear All State Files?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All State", role: .destructive) {
                Task {
                    await clearAllState()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear all collector state files and handler status files. Collectors will reprocess data on their next run. This action cannot be undone.")
        }
    }
    
    @ViewBuilder
    private var dataManagementSection: some View {
        GroupBox("Data Management") {
            VStack(alignment: .leading, spacing: 16) {
                Text("State Files")
                    .font(.headline)
                
                Text("State files track what data has been processed by collectors to avoid duplicates. Clearing state files will cause collectors to reprocess all data on their next run.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("What will be cleared:")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Collector state files (fences, hashes)", systemImage: "doc.text")
                        Label("Handler status files (run metadata)", systemImage: "clock")
                        Label("Debug output files", systemImage: "ladybug")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
                
                Button(action: {
                    showingClearConfirmation = true
                }) {
                    HStack {
                        if isClearing {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "trash")
                        }
                        Text(isClearing ? "Clearing..." : "Clear All State")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isClearing)
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private func clearResultView(_ result: ClearResult) -> some View {
        GroupBox("Clear Results") {
            VStack(alignment: .leading, spacing: 12) {
                if result.errors.isEmpty {
                    Label("Successfully cleared \(result.clearedCount) file\(result.clearedCount == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Label("Cleared \(result.clearedCount) file\(result.clearedCount == 1 ? "" : "s") with \(result.errors.count) error\(result.errors.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
                
                if !result.errors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Errors:")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        ForEach(result.errors, id: \.self) { error in
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding()
        }
    }
    
    private func clearAllState() async {
        isClearing = true
        clearResult = nil
        errorMessage = nil
        
        defer {
            isClearing = false
        }
        
        do {
            let (clearedFiles, errors) = await stateManager.clearAll()
            clearResult = ClearResult(
                clearedFiles: clearedFiles,
                errors: errors,
                clearedCount: clearedFiles.count
            )
            
            if !errors.isEmpty {
                errorMessage = "Some files could not be cleared. See details below."
            }
        } catch {
            errorMessage = "Failed to clear state: \(error.localizedDescription)"
            clearResult = ClearResult(
                clearedFiles: [],
                errors: [error.localizedDescription],
                clearedCount: 0
            )
        }
    }
}

#Preview {
    DataManagementSettingsView(errorMessage: .constant(nil))
}

