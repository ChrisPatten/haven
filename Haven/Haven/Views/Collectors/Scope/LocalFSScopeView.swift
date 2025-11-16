//
//  LocalFSScopeView.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import SwiftUI

struct LocalFSScopeView: View {
    @Binding var scopeData: [String: AnyCodable]
    
    @State private var paths: [String] = []
    @State private var includeGlobs: [String] = []
    @State private var excludeGlobs: [String] = []
    @State private var newPath: String = ""
    @State private var newIncludeGlob: String = ""
    @State private var newExcludeGlob: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Paths
            VStack(alignment: .leading, spacing: 8) {
                Text("Paths")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                HStack {
                    TextField("Enter path (e.g., ~/Documents)", text: $newPath)
                        .textFieldStyle(.roundedBorder)
                    
                    Button("Add") {
                        if !newPath.isEmpty {
                            paths.append(newPath)
                            newPath = ""
                            updateScope()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                
                if !paths.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(paths, id: \.self) { path in
                            HStack {
                                Text(path)
                                    .font(.caption)
                                Spacer()
                                Button(action: {
                                    paths.removeAll { $0 == path }
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
            
            Divider()
            
            // Test Scan
            Button(action: testScan) {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Test Scan (simulate N)")
                }
            }
            .buttonStyle(.bordered)
        }
        .onAppear {
            loadScope()
        }
    }
    
    private func loadScope() {
        // Load from scopeData
        if let pathsValue = scopeData["paths"] {
            // TODO: Parse paths array
        }
        if let includeValue = scopeData["include_globs"] {
            // TODO: Parse include_globs array
        }
        if let excludeValue = scopeData["exclude_globs"] {
            // TODO: Parse exclude_globs array
        }
    }
    
    private func updateScope() {
        // TODO: Update scopeData with paths, include_globs, exclude_globs
        // For now, placeholder
    }
    
    private func testScan() {
        // TODO: Test scan with simulate mode
    }
}

