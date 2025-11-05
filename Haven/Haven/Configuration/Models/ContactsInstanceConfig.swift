//
//  ContactsInstanceConfig.swift
//  Haven
//
//  Contacts collector instance configuration
//  Persisted in ~/.haven/contacts.plist
//

import Foundation

/// Contacts collector instances configuration
public struct ContactsInstancesConfig: Codable, @unchecked Sendable {
    public var instances: [ContactsInstance]
    
    public init(instances: [ContactsInstance] = []) {
        self.instances = instances
    }
}

/// Individual contacts collector instance
public struct ContactsInstance: Codable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var sourceType: ContactsSourceType
    public var vcfDirectory: String?  // Path to VCF directory (if sourceType is .vcf)
    public var fswatchEnabled: Bool?  // File System Watch for VCF sources
    public var fswatchDelaySeconds: Int?  // Delay/cooldown period for FSWatch
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case sourceType = "source_type"
        case vcfDirectory = "vcf_directory"
        case fswatchEnabled = "fswatch_enabled"
        case fswatchDelaySeconds = "fswatch_delay_seconds"
    }
    
    public init(
        id: String = UUID().uuidString,
        name: String = "",
        enabled: Bool = true,
        sourceType: ContactsSourceType = .macOSContacts,
        vcfDirectory: String? = nil,
        fswatchEnabled: Bool? = nil,
        fswatchDelaySeconds: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.sourceType = sourceType
        self.vcfDirectory = vcfDirectory
        self.fswatchEnabled = fswatchEnabled
        self.fswatchDelaySeconds = fswatchDelaySeconds
    }
}

/// Contacts source type
public enum ContactsSourceType: String, Codable {
    case macOSContacts = "macos_contacts"
    case vcf = "vcf"
}

