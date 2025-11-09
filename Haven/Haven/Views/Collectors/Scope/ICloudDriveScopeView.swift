//
//  ICloudDriveScopeView.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import SwiftUI

struct ICloudDriveScopeView: View {
    @Binding var scopeData: [String: AnyCodable]
    
    @State private var path: String = ""
    @State private var includeGlobs: [String] = []
    @State private var excludeGlobs: [String] = []
    @State private var newIncludeGlob: String = ""
    @State private var newExcludeGlob: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Path (optional - defaults to iCloud Drive root)
            VStack(alignment: .leading, spacing: 8) {
                Text("Path (Optional)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                Text("Leave empty to use default iCloud Drive root, or specify a subfolder path")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                TextField("Enter path (e.g., Documents/Work)", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: path) { _, _ in
                        updateScope()
                    }
            }
            
            Divider()
            
            // Include Globs
            VStack(alignment: .leading, spacing: 8) {
                Text("Include Patterns")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                HStack {
                    TextField("Enter glob pattern (e.g., **/*.pdf)", text: $newIncludeGlob)
                        .textFieldStyle(.roundedBorder)
                    
                    Button("Add") {
                        if !newIncludeGlob.isEmpty {
                            includeGlobs.append(newIncludeGlob)
                            newIncludeGlob = ""
                            updateScope()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                
                if !includeGlobs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(includeGlobs, id: \.self) { glob in
                            HStack {
                                Text(glob)
                                    .font(.caption)
                                Spacer()
                                Button(action: {
                                    includeGlobs.removeAll { $0 == glob }
                                    updateScope()
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Divider()
            
            // Exclude Globs
            VStack(alignment: .leading, spacing: 8) {
                Text("Exclude Patterns")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                HStack {
                    TextField("Enter glob pattern (e.g., **/.git/**)", text: $newExcludeGlob)
                        .textFieldStyle(.roundedBorder)
                    
                    Button("Add") {
                        if !newExcludeGlob.isEmpty {
                            excludeGlobs.append(newExcludeGlob)
                            newExcludeGlob = ""
                            updateScope()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                
                if !excludeGlobs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(excludeGlobs, id: \.self) { glob in
                            HStack {
                                Text(glob)
                                    .font(.caption)
                                Spacer()
                                Button(action: {
                                    excludeGlobs.removeAll { $0 == glob }
                                    updateScope()
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear {
            loadScope()
        }
    }
    
    private func loadScope() {
        // Load from scopeData
        if let pathValue = scopeData["path"], case .string(let pathStr) = pathValue {
            path = pathStr
        }
        
        if let includeValue = scopeData["include_globs"] {
            // Parse array from AnyCodable
            if case .string(let str) = includeValue {
                // Single string - convert to array
                includeGlobs = [str]
            }
            // TODO: Handle array parsing if needed
        }
        
        if let excludeValue = scopeData["exclude_globs"] {
            // Parse array from AnyCodable
            if case .string(let str) = excludeValue {
                // Single string - convert to array
                excludeGlobs = [str]
            }
            // TODO: Handle array parsing if needed
        }
    }
    
    private func updateScope() {
        // Update scopeData with current values
        if !path.isEmpty {
            scopeData["path"] = .string(path)
        } else {
            scopeData.removeValue(forKey: "path")
        }
        
        if !includeGlobs.isEmpty {
            // TODO: Convert array to AnyCodable properly
            // For now, store as comma-separated string
            scopeData["include_globs"] = .string(includeGlobs.joined(separator: ","))
        } else {
            scopeData.removeValue(forKey: "include_globs")
        }
        
        if !excludeGlobs.isEmpty {
            // TODO: Convert array to AnyCodable properly
            // For now, store as comma-separated string
            scopeData["exclude_globs"] = .string(excludeGlobs.joined(separator: ","))
        } else {
            scopeData.removeValue(forKey: "exclude_globs")
        }
    }
}

