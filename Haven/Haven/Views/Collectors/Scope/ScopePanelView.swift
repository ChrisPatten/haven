//
//  ScopePanelView.swift
//  Haven
//
//  Created by Chris Patten on 11/4/25.
//

import SwiftUI

struct ScopePanelView: View {
    let collector: CollectorInfo
    @Binding var scopeData: [String: AnyCodable]
    let modulesResponse: ModulesResponse?
    let hostAgentController: HostAgentController?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let baseCollectorId = extractBaseCollectorId(collector.id)
            
            switch baseCollectorId {
            case "imessage":
                IMessageScopeView(
                    scopeData: $scopeData,
                    ocrEnabled: modulesResponse?.ocr?.enabled ?? false,
                    entityEnabled: modulesResponse?.entity?.enabled ?? false
                )
                
            case "email_imap":
                IMAPScopeView(
                    collector: collector,
                    scopeData: $scopeData,
                    hostAgentController: hostAgentController
                )
                
            case "localfs":
                LocalFSScopeView(scopeData: $scopeData)
                
            case "icloud_drive":
                ICloudDriveScopeView(scopeData: $scopeData)
                
            case "contacts":
                ContactsScopeView(scopeData: $scopeData)
                
            case "reminders":
                RemindersScopeView(
                    scopeData: $scopeData,
                    hostAgentController: hostAgentController
                )
            
            default:
                Text("Scope configuration not available for this collector")
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func extractBaseCollectorId(_ collectorId: String) -> String {
        if let colonIndex = collectorId.firstIndex(of: ":") {
            return String(collectorId[..<colonIndex])
        }
        return collectorId
    }
}

// MARK: - ModulesResponse

struct ModulesResponse: Codable {
    let ocr: ModuleConfig?
    let entity: ModuleConfig?
    
    struct ModuleConfig: Codable {
        let enabled: Bool
        
        init(enabled: Bool) {
            self.enabled = enabled
        }
    }
    
    init(ocr: ModuleConfig? = nil, entity: ModuleConfig? = nil) {
        self.ocr = ocr
        self.entity = entity
    }
}

