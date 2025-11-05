//
//  ConfigConverter.swift
//  Haven
//
//  Converter between plist configuration models and HavenCore HavenConfig
//  for compatibility with existing HavenCore code
//

import Foundation

/// Converter between plist configuration models and HavenCore HavenConfig
public struct ConfigConverter {
    
    /// Convert plist-based SystemConfig to HavenCore HavenConfig
    public static func toHavenConfig(
        systemConfig: SystemConfig,
        emailConfig: EmailInstancesConfig,
        filesConfig: FilesInstancesConfig,
        contactsConfig: ContactsInstancesConfig,
        imessageConfig: IMessageInstanceConfig
    ) -> HavenConfig {
        // Convert email instances back to mail sources
        var mailSources: [MailSourceConfig]? = nil
        if !emailConfig.instances.isEmpty {
            mailSources = emailConfig.instances.map { instance in
                MailSourceConfig(
                    id: instance.id,
                    type: instance.type,
                    enabled: instance.enabled,
                    host: instance.host,
                    port: instance.port,
                    username: instance.username,
                    tls: instance.tls,
                    folders: instance.folders,
                    auth: instance.auth != nil ? MailSourceAuthConfig(
                        kind: instance.auth?.kind,
                        secretRef: instance.auth?.secretRef
                    ) : nil
                )
            }
        }
        
        // Determine mail module redactPii
        let mailRedactPii: Bool
        if let moduleRedactPii = emailConfig.moduleRedactPii {
            switch moduleRedactPii {
            case .boolean(let value):
                mailRedactPii = value
            case .detailed:
                mailRedactPii = true  // Default to true if detailed
            }
        } else {
            mailRedactPii = true  // Default
        }
        
        return HavenConfig(
            service: ServiceConfig(
                port: systemConfig.service.port,
                auth: AuthConfig(
                    header: systemConfig.service.auth.header,
                    secret: systemConfig.service.auth.secret
                )
            ),
            api: ApiConfig(
                responseTimeoutMs: systemConfig.api.responseTimeoutMs,
                statusTtlMinutes: systemConfig.api.statusTtlMinutes
            ),
            gateway: GatewayConfig(
                baseUrl: systemConfig.gateway.baseUrl,
                ingestPath: systemConfig.gateway.ingestPath,
                ingestFilePath: systemConfig.gateway.ingestFilePath,
                timeoutMs: systemConfig.gateway.timeoutMs
            ),
            logging: LoggingConfig(
                level: systemConfig.logging.level,
                format: systemConfig.logging.format,
                paths: LoggingPathsConfig(
                    output: systemConfig.logging.paths.app,
                    error: systemConfig.logging.paths.error
                )
            ),
            modules: ModulesConfig(
                imessage: IMessageModuleConfig(
                    enabled: systemConfig.modules.imessage,
                    chatDbPath: imessageConfig.chatDbPath,
                    ocrEnabled: imessageConfig.ocrEnabled,
                    attachmentsPath: imessageConfig.attachmentsPath
                ),
                ocr: OCRModuleConfig(
                    enabled: systemConfig.modules.ocr,
                    timeoutMs: systemConfig.advanced.ocr.timeoutMs,
                    languages: systemConfig.advanced.ocr.languages,
                    recognitionLevel: systemConfig.advanced.ocr.recognitionLevel,
                    includeLayout: systemConfig.advanced.ocr.includeLayout,
                    maxImageDimension: 1600  // Default
                ),
                entity: EntityModuleConfig(
                    enabled: systemConfig.modules.entity,
                    types: systemConfig.advanced.entity.types,
                    minConfidence: systemConfig.advanced.entity.minConfidence
                ),
                face: FaceModuleConfig(
                    enabled: systemConfig.modules.face,
                    minFaceSize: systemConfig.advanced.face.minFaceSize,
                    minConfidence: systemConfig.advanced.face.minConfidence,
                    includeLandmarks: systemConfig.advanced.face.includeLandmarks
                ),
                fswatch: FSWatchModuleConfig(
                    enabled: systemConfig.modules.fswatch,
                    watches: [],
                    eventQueueSize: systemConfig.advanced.fswatch.eventQueueSize
                ),
                localfs: LocalFSModuleConfig(
                    enabled: systemConfig.modules.localfs,
                    maxFileBytes: systemConfig.advanced.localfs.maxFileBytes
                ),
                contacts: StubModuleConfig(
                    enabled: systemConfig.modules.contacts
                ),
                mail: MailModuleConfig(
                    enabled: systemConfig.modules.mail,
                    sources: mailSources,
                    redactPii: mailRedactPii
                )
            )
        )
    }
    
    /// Convert HavenCore HavenConfig to plist-based SystemConfig
    public static func toSystemConfig(_ config: HavenConfig) -> SystemConfig {
        return SystemConfig(
            service: SystemServiceConfig(
                port: config.service.port,
                auth: SystemAuthConfig(
                    header: config.service.auth.header,
                    secret: config.service.auth.secret
                )
            ),
            api: SystemApiConfig(
                responseTimeoutMs: config.api.responseTimeoutMs,
                statusTtlMinutes: config.api.statusTtlMinutes
            ),
            gateway: SystemGatewayConfig(
                baseUrl: config.gateway.baseUrl,
                ingestPath: config.gateway.ingestPath,
                ingestFilePath: config.gateway.ingestFilePath,
                timeoutMs: config.gateway.timeoutMs
            ),
            logging: SystemLoggingConfig(
                level: config.logging.level,
                format: config.logging.format,
                paths: SystemLoggingPathsConfig(
                    app: config.logging.paths.output,
                    error: config.logging.paths.error,
                    access: "~/.haven/hostagent_access.log"
                )
            ),
            modules: ModulesEnablementConfig(
                imessage: config.modules.imessage.enabled,
                ocr: config.modules.ocr.enabled,
                entity: config.modules.entity.enabled,
                face: config.modules.face.enabled,
                fswatch: config.modules.fswatch.enabled,
                localfs: config.modules.localfs.enabled,
                contacts: config.modules.contacts.enabled,
                mail: config.modules.mail.enabled
            ),
            advanced: AdvancedModuleSettings(
                ocr: OCRModuleSettings(
                    languages: config.modules.ocr.languages,
                    timeoutMs: config.modules.ocr.timeoutMs,
                    recognitionLevel: config.modules.ocr.recognitionLevel,
                    includeLayout: config.modules.ocr.includeLayout
                ),
                entity: EntityModuleSettings(
                    types: config.modules.entity.types,
                    minConfidence: config.modules.entity.minConfidence
                ),
                face: FaceModuleSettings(
                    minFaceSize: config.modules.face.minFaceSize,
                    minConfidence: config.modules.face.minConfidence,
                    includeLandmarks: config.modules.face.includeLandmarks
                ),
                fswatch: FSWatchModuleSettings(
                    eventQueueSize: config.modules.fswatch.eventQueueSize,
                    debounceMs: 500  // Default
                ),
                localfs: LocalFSModuleSettings(
                    maxFileBytes: 104857600  // Default 100MB
                )
            )
        )
    }
    
    /// Convert HavenCore HavenConfig to plist-based EmailInstancesConfig
    public static func toEmailConfig(_ config: HavenConfig) -> EmailInstancesConfig {
        var instances: [EmailInstance] = []
        
        if let sources = config.modules.mail.sources {
            for source in sources {
                let instance = EmailInstance(
                    id: source.id,
                    type: source.type,
                    enabled: source.enabled,
                    redactPii: nil,  // TODO: Convert if needed
                    host: source.host,
                    port: source.port,
                    tls: source.tls,
                    username: source.username,
                    auth: source.auth != nil ? EmailAuthConfig(
                        kind: source.auth?.kind ?? "app_password",
                        secretRef: source.auth?.secretRef ?? ""
                    ) : nil,
                    folders: source.folders,
                    sourcePath: nil
                )
                instances.append(instance)
            }
        }
        
        let moduleRedactPii: RedactionConfig? = config.modules.mail.redactPii ? .boolean(true) : nil
        
        return EmailInstancesConfig(
            instances: instances,
            moduleRedactPii: moduleRedactPii
        )
    }
    
    /// Convert HavenCore HavenConfig to plist-based IMessageInstanceConfig
    public static func toIMessageConfig(_ config: HavenConfig) -> IMessageInstanceConfig {
        return IMessageInstanceConfig(
            ocrEnabled: config.modules.imessage.ocrEnabled,
            chatDbPath: config.modules.imessage.chatDbPath,
            attachmentsPath: ""  // TODO: Get from config if available
        )
    }
}

