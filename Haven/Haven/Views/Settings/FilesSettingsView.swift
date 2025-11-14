//
//  FilesSettingsView.swift
//  Haven
//
//  LocalFS collector instances management view
//

import SwiftUI
import AppKit

/// Files settings view for managing LocalFS instances
struct FilesSettingsView: View {
    @Binding var config: FilesInstancesConfig?
    var configManager: ConfigManager
    @Binding var errorMessage: String?
    
    @State private var instances: [FilesInstance] = []
    @State private var selectedInstance: FilesInstance.ID?
    @State private var showingAddSheet = false
    @State private var showingEditSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button("Add Source") {
                    showingAddSheet = true
                }
                .buttonStyle(.borderedProminent)
                
                Button("Remove") {
                    removeSelectedInstance()
                }
                .disabled(selectedInstance == nil)
                
                Spacer()
            }
            .padding()
            
            Divider()
            
            // Table view
            if instances.isEmpty {
                VStack {
                    Text("No file collector instances configured")
                        .foregroundColor(.secondary)
                    Text("Click 'Add Source' to configure a file watch directory")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(instances, selection: $selectedInstance) {
                    TableColumn("Name") { instance in
                        Text(instance.name.isEmpty ? instance.id : instance.name)
                    }
                    TableColumn("Paths") { instance in
                        Text(instance.paths.joined(separator: ", "))
                            .lineLimit(1)
                    }
                    TableColumn("Enabled") { instance in
                        Toggle("", isOn: Binding(
                            get: { instance.enabled },
                            set: { newValue in
                                if let index = instances.firstIndex(where: { $0.id == instance.id }) {
                                    instances[index].enabled = newValue
                                    updateConfiguration()
                                }
                            }
                        ))
                    }
                    TableColumn("") { instance in
                        Button(action: {
                            selectedInstance = instance.id
                            showingEditSheet = true
                        }) {
                            Image(systemName: "pencil")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                    .width(30)
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            FilesInstanceEditSheet(
                instance: nil,
                onSave: { instance in
                    instances.append(instance)
                    updateConfiguration()
                }
            )
        }
        .sheet(isPresented: $showingEditSheet) {
            if let selectedId = selectedInstance,
               let instance = instances.first(where: { $0.id == selectedId }) {
                FilesInstanceEditSheet(
                    instance: instance,
                    onSave: { updatedInstance in
                        if let index = instances.firstIndex(where: { $0.id == updatedInstance.id }) {
                            instances[index] = updatedInstance
                            updateConfiguration()
                        }
                    }
                )
            }
        }
        .onAppear {
            loadConfiguration()
        }
        .onChange(of: config) { newConfig in
            loadConfiguration()
        }
        .onChange(of: selectedInstance) { _, newValue in
            // Only auto-open edit sheet if selected from table row click, not from pencil button
            // The pencil button sets showingEditSheet directly
        }
    }
    
    private func loadConfiguration() {
        guard let config = config else {
            instances = []
            return
        }
        
        instances = config.instances
    }
    
    private func updateConfiguration() {
        config = FilesInstancesConfig(instances: instances)
    }
    
    private func removeSelectedInstance() {
        guard let selectedId = selectedInstance else { return }
        instances.removeAll { $0.id == selectedId }
        selectedInstance = nil
        updateConfiguration()
    }
}

/// Sheet for editing a files instance
struct FilesInstanceEditSheet: View {
    let instance: FilesInstance?
    let onSave: (FilesInstance) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var id: String = ""
    @State private var name: String = ""
    @State private var enabled: Bool = true
    @State private var watchDirectory: String = ""
    @State private var includeChildDirectories: Bool = true
    @State private var includeGlobs: [String] = ["*.txt", "*.md", "*.pdf"]
    @State private var excludeGlobs: [String] = []
    @State private var tags: [String] = []
    @State private var moveTo: String = ""
    @State private var deleteAfter: Bool = false
    @State private var followSymlinks: Bool = false
    @State private var showingDirectoryPicker: Bool = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display Name", text: $name, prompt: Text("e.g., Documents"))
                        .help("A friendly name for this file source")
                    
                    Toggle("Enabled", isOn: $enabled)
                }
                
                Section {
                    HStack {
                        TextField("Select directory...", text: $watchDirectory, prompt: Text("/path/to/directory"))
                        Button("Browse...") {
                            selectDirectory()
                        }
                    }
                    
                    Toggle("Include child directories", isOn: $includeChildDirectories)
                } header: {
                    Text("Watch Directory")
                } footer: {
                    Text("The directory to watch for file changes")
                }
                
                Section {
                    if !includeGlobs.isEmpty {
                        ForEach(Array(includeGlobs.indices), id: \.self) { index in
                            HStack {
                                TextField(
                                    "Pattern",
                                    text: bindingForIncludeGlob(index: index),
                                    prompt: Text("*.txt, *.pdf, etc.")
                                )
                                Button(action: {
                                    includeGlobs.remove(at: index)
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    Button(action: {
                        includeGlobs.append("")
                    }) {
                        Label("Add Pattern", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Include Patterns")
                } footer: {
                    Text("Glob patterns for files to include (e.g., *.txt, *.pdf)")
                }
                
                Section {
                    if !excludeGlobs.isEmpty {
                        ForEach(Array(excludeGlobs.indices), id: \.self) { index in
                            HStack {
                                TextField(
                                    "Pattern",
                                    text: bindingForExcludeGlob(index: index),
                                    prompt: Text("*.tmp, .DS_Store, etc.")
                                )
                                Button(action: {
                                    excludeGlobs.remove(at: index)
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    Button(action: {
                        excludeGlobs.append("")
                    }) {
                        Label("Add Pattern", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Exclude Patterns")
                } footer: {
                    Text("Glob patterns for files to exclude from processing")
                }
                
                Section {
                    TextField("Move To Directory", text: $moveTo, prompt: Text("/path/to/processed"))
                        .help("Optional: Move files to this directory after processing")
                    
                    Toggle("Delete After Processing", isOn: $deleteAfter)
                    
                    Toggle("Follow Symbolic Links", isOn: $followSymlinks)
                } header: {
                    Text("Options")
                } footer: {
                    Text("Advanced options for file processing behavior")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(instance == nil ? "Add File Source" : "Edit File Source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let instance = FilesInstance(
                            id: instance?.id ?? UUID().uuidString,
                            name: name,
                            enabled: enabled,
                            paths: watchDirectory.isEmpty ? [] : [watchDirectory],
                            includeGlobs: includeGlobs.filter { !$0.isEmpty },
                            excludeGlobs: excludeGlobs.filter { !$0.isEmpty },
                            tags: tags.filter { !$0.isEmpty },
                            moveTo: moveTo.isEmpty ? nil : moveTo,
                            deleteAfter: deleteAfter,
                            followSymlinks: followSymlinks || includeChildDirectories
                        )
                        onSave(instance)
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 600, height: 700)
        .onAppear {
            if let instance = instance {
                id = instance.id
                name = instance.name
                enabled = instance.enabled
                watchDirectory = instance.paths.first ?? ""
                includeChildDirectories = instance.followSymlinks
                includeGlobs = instance.includeGlobs
                excludeGlobs = instance.excludeGlobs
                tags = instance.tags
                moveTo = instance.moveTo ?? ""
                deleteAfter = instance.deleteAfter
                followSymlinks = instance.followSymlinks
            } else {
                id = UUID().uuidString
            }
        }
    }

    private func bindingForIncludeGlob(index: Int) -> Binding<String> {
        Binding(
            get: {
                guard includeGlobs.indices.contains(index) else { return "" }
                return includeGlobs[index]
            },
            set: { newValue in
                guard includeGlobs.indices.contains(index) else { return }
                includeGlobs[index] = newValue
            }
        )
    }

    private func bindingForExcludeGlob(index: Int) -> Binding<String> {
        Binding(
            get: {
                guard excludeGlobs.indices.contains(index) else { return "" }
                return excludeGlobs[index]
            },
            set: { newValue in
                guard excludeGlobs.indices.contains(index) else { return }
                excludeGlobs[index] = newValue
            }
        )
    }
    
    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                watchDirectory = url.path
            }
        }
    }
}

