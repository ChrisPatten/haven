//
//  iMessageScopeView.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import SwiftUI

struct IMessageScopeView: View {
    @Binding var scopeData: [String: AnyCodable]
    let ocrEnabled: Bool
    let entityEnabled: Bool
    
    @State private var includeChats: [String] = []
    @State private var excludeChats: [String] = []
    @State private var includeAttachments: Bool = false
    @State private var useOcrOnAttachments: Bool = false
    @State private var extractEntities: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chat Filters")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                // TODO: Add chat selector UI
                Text("Chat selection UI coming soon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Include Attachments", isOn: $includeAttachments)
                    .onChange(of: includeAttachments) { _, _ in updateScope() }
                
                Toggle("Use OCR on Attachments", isOn: $useOcrOnAttachments)
                    .disabled(!ocrEnabled)
                    .help(ocrEnabled ? "" : "Enable OCR module in Settings")
                    .onChange(of: useOcrOnAttachments) { _, _ in updateScope() }
                
                Toggle("Extract Entities", isOn: $extractEntities)
                    .disabled(!entityEnabled)
                    .help(entityEnabled ? "" : "Enable Entity module in Settings")
                    .onChange(of: extractEntities) { _, _ in updateScope() }
            }
        }
        .onAppear {
            // Initialize state variables from scopeData binding
            if let includeAttachmentsVal = scopeData["include_attachments"], case .bool(let val) = includeAttachmentsVal {
                includeAttachments = val
            }
            if let useOcrVal = scopeData["use_ocr_on_attachments"], case .bool(let val) = useOcrVal {
                useOcrOnAttachments = val
            }
            if let extractEntitiesVal = scopeData["extract_entities"], case .bool(let val) = extractEntitiesVal {
                extractEntities = val
            }
            
            // Ensure scopeData is synced with current state values
            updateScope()
        }
    }
    
    private func updateScope() {
        scopeData["include_attachments"] = .bool(includeAttachments)
        scopeData["use_ocr_on_attachments"] = .bool(useOcrOnAttachments)
        scopeData["extract_entities"] = .bool(extractEntities)
        
        // TODO: Handle include_chats and exclude_chats arrays when implemented
    }
}

