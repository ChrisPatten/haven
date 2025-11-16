//
//  EnrichmentSettingsView.swift
//  Haven
//
//  Created on 12/28/24.
//

import SwiftUI

/// Enrichment settings view for per-collector enrichment configuration
struct EnrichmentSettingsView: View {
    @State private var enrichmentConfig: CollectorEnrichmentConfig = CollectorEnrichmentConfig()
    @State private var enrichmentConfigManager = EnrichmentConfigManager()
    @Binding var errorMessage: String?
    
    // Collector IDs
    private let collectors = [
        ("email_imap", "Email (IMAP)"),
        ("localfs", "Files"),
        ("imessage", "iMessage"),
        ("contacts", "Contacts")
    ]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Enrichment Settings")
                    .font(.title2)
                    .padding(.bottom, 10)
                
                Text("Configure enrichment settings for each collector. When enrichment is skipped, documents are submitted without OCR, face detection, entity extraction, or captioning.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 10)
                
                Divider()
                
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(collectors, id: \.0) { collectorId, collectorName in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(collectorName)
                                    .font(.headline)
                                if collectorId == "contacts" {
                                    Text("Contacts always skip enrichment")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Spacer()
                            
                            Toggle("Skip Enrichment", isOn: Binding(
                                get: {
                                    enrichmentConfig.getSkipEnrichment(for: collectorId)
                                },
                                set: { newValue in
                                    enrichmentConfig.setSkipEnrichment(for: collectorId, skip: newValue)
                                    saveConfiguration()
                                }
                            ))
                            .disabled(collectorId == "contacts") // Contacts always skip
                        }
                        .padding(.vertical, 8)
                        
                        if collectorId != collectors.last?.0 {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 10)
                
                Divider()
                
                Text("Note: Global enrichment service settings (OCR, Face Detection, NER, Captioning) can be configured in Advanced Settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
            }
            .padding()
        }
        .onAppear {
            loadConfiguration()
        }
    }
    
    private func loadConfiguration() {
        enrichmentConfig = enrichmentConfigManager.loadEnrichmentConfig()
    }
    
    private func saveConfiguration() {
        do {
            try enrichmentConfigManager.saveEnrichmentConfig(enrichmentConfig)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save enrichment configuration: \(error.localizedDescription)"
        }
    }
}

#Preview {
    EnrichmentSettingsView(errorMessage: .constant(nil))
}

