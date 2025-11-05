//
//  EmailInstanceConfig.swift
//  Haven
//
//  Email collector instance configuration
//  Persisted in ~/.haven/email.plist
//

import Foundation

/// Email collector instances configuration
public struct EmailInstancesConfig: Codable, @unchecked Sendable {
    public var instances: [EmailInstance]
    public var moduleRedactPii: RedactionConfig?
    
    enum CodingKeys: String, CodingKey {
        case instances
        case moduleRedactPii = "module_redact_pii"
    }
    
    public init(instances: [EmailInstance] = [], moduleRedactPii: RedactionConfig? = nil) {
        self.instances = instances
        self.moduleRedactPii = moduleRedactPii
    }
}

/// Individual email collector instance (IMAP account or local source)
public struct EmailInstance: Codable, Identifiable {
    public var id: String
    public var displayName: String?
    public var type: String  // "imap" or "local"
    public var enabled: Bool
    public var redactPii: RedactionConfig?
    
    // IMAP-specific fields
    public var host: String?
    public var port: Int?
    public var tls: Bool?
    public var username: String?
    public var auth: EmailAuthConfig?
    public var folders: [String]?
    
    // Local-specific fields
    public var sourcePath: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case type
        case enabled
        case redactPii = "redact_pii"
        case host
        case port
        case tls
        case username
        case auth
        case folders
        case sourcePath = "source_path"
    }
    
    public init(
        id: String = UUID().uuidString,
        displayName: String? = nil,
        type: String = "imap",
        enabled: Bool = true,
        redactPii: RedactionConfig? = nil,
        host: String? = nil,
        port: Int? = nil,
        tls: Bool? = nil,
        username: String? = nil,
        auth: EmailAuthConfig? = nil,
        folders: [String]? = nil,
        sourcePath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.type = type
        self.enabled = enabled
        self.redactPii = redactPii
        self.host = host
        self.port = port
        self.tls = tls
        self.username = username
        self.auth = auth
        self.folders = folders
        self.sourcePath = sourcePath
    }
}

/// Email authentication configuration
public struct EmailAuthConfig: Codable {
    public var kind: String  // "app_password", "oauth2", etc.
    public var secretRef: String  // Keychain reference
    
    enum CodingKeys: String, CodingKey {
        case kind
        case secretRef = "secret_ref"
    }
    
    public init(kind: String = "app_password", secretRef: String = "") {
        self.kind = kind
        self.secretRef = secretRef
    }
}

/// PII redaction configuration (boolean or detailed)
public enum RedactionConfig: Codable {
    case boolean(Bool)
    case detailed(RedactionOptions)
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        // Try to decode as boolean first
        if let boolValue = try? container.decode(Bool.self) {
            self = .boolean(boolValue)
            return
        }
        
        // Try to decode as detailed options
        if let options = try? container.decode(RedactionOptions.self) {
            self = .detailed(options)
            return
        }
        
        throw DecodingError.typeMismatch(
            RedactionConfig.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected Bool or RedactionOptions"
            )
        )
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .boolean(let value):
            try container.encode(value)
        case .detailed(let options):
            try container.encode(options)
        }
    }
}

/// Detailed PII redaction options
public struct RedactionOptions: Codable {
    public var emails: Bool
    public var phones: Bool
    public var accountNumbers: Bool
    public var ssn: Bool
    
    enum CodingKeys: String, CodingKey {
        case emails
        case phones
        case accountNumbers = "account_numbers"
        case ssn
    }
    
    public init(emails: Bool = true, phones: Bool = true, accountNumbers: Bool = true, ssn: Bool = true) {
        self.emails = emails
        self.phones = phones
        self.accountNumbers = accountNumbers
        self.ssn = ssn
    }
}

