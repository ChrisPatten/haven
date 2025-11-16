//
//  ContactsScopeView.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import SwiftUI

struct ContactsScopeView: View {
    @Binding var scopeData: [String: AnyCodable]
    
    @State private var useVCFDirectory: Bool = false
    @State private var vcfDirectory: String = ""
    @State private var permissionStatus: String = "Unknown"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Permission Status
            VStack(alignment: .leading, spacing: 8) {
                Text("Permission Status")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                HStack {
                    Circle()
                        .fill(permissionStatus == "Granted" ? .green : .red)
                        .frame(width: 8, height: 8)
                    
                    Text(permissionStatus)
                        .font(.caption)
                    
                    Spacer()
                    
                    Button("Check Permissions") {
                        checkPermissions()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                if permissionStatus != "Granted" {
                    Text("Contacts access is required. Please grant access in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Button("Open Permissions Panel") {
                        // TODO: Open permissions panel or deeplink to Settings
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
            
            Divider()
            
            // VCF Directory Option
            VStack(alignment: .leading, spacing: 8) {
                Text("Source")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                Toggle("Use VCF Directory Instead of macOS Contacts", isOn: $useVCFDirectory)
                    .onChange(of: useVCFDirectory) { _, _ in updateScope() }
                
                if useVCFDirectory {
                    HStack {
                        TextField("Enter VCF directory path", text: $vcfDirectory)
                            .textFieldStyle(.roundedBorder)
                        
                        Button("Browse...") {
                            // TODO: Open file picker for directory selection
                        }
                        .buttonStyle(.bordered)
                    }
                    .onChange(of: vcfDirectory) { _, _ in updateScope() }
                }
            }
        }
        .onAppear {
            checkPermissions()
            loadScope()
        }
    }
    
    private func checkPermissions() {
        // TODO: Check TCC permissions via HostAgent API
        // For now, placeholder
        permissionStatus = "Unknown"
    }
    
    private func loadScope() {
        if let useVCFValue = scopeData["use_vcf_directory"], case .bool(let val) = useVCFValue {
            useVCFDirectory = val
        }
        if let dirValue = scopeData["vcf_directory"], case .string(let dir) = dirValue {
            vcfDirectory = dir
        }
    }
    
    private func updateScope() {
        scopeData["use_vcf_directory"] = .bool(useVCFDirectory)
        if !vcfDirectory.isEmpty {
            scopeData["vcf_directory"] = .string(vcfDirectory)
        }
    }
}

