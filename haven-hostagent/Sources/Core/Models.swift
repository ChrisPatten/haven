import Foundation

public struct HealthResponse: Codable, Sendable {
    public var status: String
    public var startedAt: Date
    public var version: String
    public var moduleSummaries: [ModuleSummary]
    
    public init(status: String, startedAt: Date, version: String, moduleSummaries: [ModuleSummary]) {
        self.status = status
        self.startedAt = startedAt
        self.version = version
        self.moduleSummaries = moduleSummaries
    }
}

public struct CapabilitiesResponse: Codable, Sendable {
    public var declaredModules: [ModuleCapability]
    
    public init(declaredModules: [ModuleCapability]) {
        self.declaredModules = declaredModules
    }
}

public struct ModuleCapability: Codable, Sendable {
    public var name: String
    public var enabled: Bool
    public var permissions: [PermissionStatus]
    public var description: String
    
    public init(name: String, enabled: Bool, permissions: [PermissionStatus], description: String) {
        self.name = name
        self.enabled = enabled
        self.permissions = permissions
        self.description = description
    }
}

public struct PermissionStatus: Codable, Sendable {
    public var name: String
    public var granted: Bool
    public var details: String?
    
    public init(name: String, granted: Bool, details: String?) {
        self.name = name
        self.granted = granted
        self.details = details
    }
}

public struct MetricsResponse: Sendable {
    public var body: String
}

public struct ModuleUpdateRequest<Config: Codable & Sendable>: Codable, Sendable {
    public var enabled: Bool
    public var config: Config
}
