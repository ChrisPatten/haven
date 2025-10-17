import Core
import Foundation
import Logging
import NIOHTTP1

public actor HostHTTPRouter {
    private let logger = Logger(label: "HostAgent.HostHTTPRouter")
    private let startTime = Date()
    private let moduleManager: ModuleManager
    private let imessages: IMessagesService
    private let ocr: OCRService
    private let fswatch: FSWatchService
    private let authHeader: String
    private let authSecret: String

    public init(
        moduleManager: ModuleManager,
        imessages: IMessagesService,
        ocr: OCRService,
        fswatch: FSWatchService,
        authHeader: String,
        authSecret: String
    ) {
        self.moduleManager = moduleManager
        self.imessages = imessages
        self.ocr = ocr
        self.fswatch = fswatch
        self.authHeader = authHeader
        self.authSecret = authSecret
    }

    public func handle(_ request: HostHTTPRequest) async -> HostHTTPResponse {
        do {
            guard validateAuth(request: request) else {
                return HostHTTPResponse.text("unauthorized", status: .unauthorized)
            }

            switch (request.method, request.path) {
            case (.GET, "/v1/health"):
                return try await health()
            case (.GET, "/v1/capabilities"):
                return try await capabilities()
            case (.GET, "/v1/metrics"):
                return metrics()
            case (.GET, "/v1/modules"):
                return try await modules()
            case (.PUT, let path) where path.hasPrefix("/v1/modules/"):
                return try await updateModule(path: path, body: request.body)
            case (.POST, "/v1/collectors/imessage:run"):
                return try await runIMessages(body: request.body)
            case (.GET, "/v1/collectors/imessage/state"):
                return try await imessagesState()
            case (.GET, "/v1/collectors/imessage/logs"):
                return try await imessagesLogs(query: request.query)
            case (.POST, "/v1/ocr"):
                return try await performOCR(request: request)
            case (.GET, "/v1/ocr/health"):
                return try await ocrHealth()
            case (.POST, "/v1/fs-watches"):
                return try await createWatch(body: request.body)
            case (.GET, "/v1/fs-watches"):
                return try await listWatches()
            case (.DELETE, let path) where path.hasPrefix("/v1/fs-watches/"):
                return try await deleteWatch(path: path)
            default:
                return HostHTTPResponse.text("not found", status: .notFound)
            }
        } catch {
            logger.error("Request failed", metadata: ["error": "\(error)", "path": "\(request.path)"])
            return HostHTTPResponse.text("internal error", status: .internalServerError)
        }
    }

    private func validateAuth(request: HostHTTPRequest) -> Bool {
        guard !authSecret.isEmpty else { return true }
        guard let headerValue = request.header(authHeader) else { return false }
        return headerValue == authSecret
    }

    private func health() async throws -> HostHTTPResponse {
        let moduleSummaries = await moduleManager.summaries()
        let response = HealthResponse(
            status: "ok",
            startedAt: startTime,
            version: HostAgentVersion.current,
            moduleSummaries: moduleSummaries
        )
        return HostHTTPResponse.json(response)
    }

    private func capabilities() async throws -> HostHTTPResponse {
        let config = await moduleManager.configuration()
        var modules: [ModuleCapability] = []
        modules.append(ModuleCapability(
            name: "imessage",
            enabled: config.modules.imessage.enabled,
            permissions: [
                PermissionStatus(name: "Full Disk Access", granted: PermissionChecker.hasFullDiskAccess(), details: nil)
            ],
            description: "iMessage collector with OCR enrichment"
        ))
        modules.append(ModuleCapability(
            name: "ocr",
            enabled: config.modules.ocr.enabled,
            permissions: [
                PermissionStatus(name: "Vision OCR", granted: true, details: "macOS Vision framework")
            ],
            description: "Vision-based OCR service"
        ))
        modules.append(ModuleCapability(
            name: "fswatch",
            enabled: config.modules.fswatch.enabled,
            permissions: [
                PermissionStatus(name: "File Access", granted: PermissionChecker.hasFullDiskAccess(), details: "Required for watched directories")
            ],
            description: "Filesystem watcher for ingest"
        ))

        let response = CapabilitiesResponse(declaredModules: modules)
        return HostHTTPResponse.json(response)
    }

    private func metrics() -> HostHTTPResponse {
        let body = "# haven_hostagent_metrics\n"
        return HostHTTPResponse.text(body, contentType: "text/plain; version=0.0.4")
    }

    private func modules() async throws -> HostHTTPResponse {
        let summaries = await moduleManager.summaries()
        return HostHTTPResponse.json(["modules": summaries])
    }

    private func updateModule(path: String, body: Data) async throws -> HostHTTPResponse {
        let name = String(path.dropFirst("/v1/modules/".count))
        guard let kind = ModuleKind(rawValue: name) else {
            return HostHTTPResponse.text("unknown module", status: .notFound)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        switch kind {
        case .imessage:
            struct Payload: Codable { let enabled: Bool; let config: HostAgentConfiguration.IMessagesConfig }
            let payload = try decoder.decode(Payload.self, from: body)
            try await moduleManager.updateConfiguration { config in
                config.modules.imessage.enabled = payload.enabled
                config.modules.imessage.config = payload.config
            }
            await imessages.updateConfiguration(payload.config)
            await moduleManager.applyModuleState(kind: kind, enabled: payload.enabled)
        case .ocr:
            struct Payload: Codable { let enabled: Bool; let config: HostAgentConfiguration.OCRConfig }
            let payload = try decoder.decode(Payload.self, from: body)
            try await moduleManager.updateConfiguration { config in
                config.modules.ocr.enabled = payload.enabled
                config.modules.ocr.config = payload.config
            }
            await ocr.updateConfiguration(payload.config)
            await imessages.updateOCRLanguages(payload.config.languages)
            await moduleManager.applyModuleState(kind: kind, enabled: payload.enabled)
        case .fswatch:
            struct Payload: Codable { let enabled: Bool; let config: HostAgentConfiguration.FSWatchConfig }
            let payload = try decoder.decode(Payload.self, from: body)
            try await moduleManager.updateConfiguration { config in
                config.modules.fswatch.enabled = payload.enabled
                config.modules.fswatch.config = payload.config
            }
            await fswatch.updateConfiguration(payload.config)
            await moduleManager.applyModuleState(kind: kind, enabled: payload.enabled)
        case .contacts, .calendar, .reminders, .mail, .notes, .faces:
            struct Payload: Codable { let enabled: Bool }
            let payload = try decoder.decode(Payload.self, from: body)
            try await moduleManager.updateConfiguration { config in
                switch kind {
                case .contacts:
                    config.modules.contacts.enabled = payload.enabled
                case .calendar:
                    config.modules.calendar.enabled = payload.enabled
                case .reminders:
                    config.modules.reminders.enabled = payload.enabled
                case .mail:
                    config.modules.mail.enabled = payload.enabled
                case .notes:
                    config.modules.notes.enabled = payload.enabled
                case .faces:
                    config.modules.faces.enabled = payload.enabled
                default:
                    break
                }
            }
            await moduleManager.applyModuleState(kind: kind, enabled: payload.enabled)
        }
        return HostHTTPResponse.noContent()
    }

    private func runIMessages(body: Data) async throws -> HostHTTPResponse {
        guard await isModuleEnabled(.imessage) else {
            return HostHTTPResponse.text("module disabled", status: .conflict)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let request = try decoder.decode(IMessagesRunRequest.self, from: body)
        let result = try await imessages.run(request: request)
        return HostHTTPResponse.json(result)
    }

    private func imessagesState() async throws -> HostHTTPResponse {
        guard await isModuleEnabled(.imessage) else {
            return HostHTTPResponse.text("module disabled", status: .conflict)
        }
        let state = await imessages.state()
        return HostHTTPResponse.json(state)
    }

    private func imessagesLogs(query: [String: String]) async throws -> HostHTTPResponse {
        guard await isModuleEnabled(.imessage) else {
            return HostHTTPResponse.text("module disabled", status: .conflict)
        }
        let sinceString = query["since"] ?? "5m"
        let interval = parseInterval(sinceString) ?? 600
        let logs = await imessages.logs(since: interval)
        return HostHTTPResponse.json(["entries": logs])
    }

    private func performOCR(request: HostHTTPRequest) async throws -> HostHTTPResponse {
        guard await isModuleEnabled(.ocr) else {
            return HostHTTPResponse.text("module disabled", status: .conflict)
        }

        if let contentType = request.headers.first(name: "Content-Type"), contentType.starts(with: "multipart/form-data") {
            guard let boundary = contentType.components(separatedBy: "boundary=").last else {
                return HostHTTPResponse.text("boundary missing", status: .badRequest)
            }
            let parser = MultipartParser(boundary: boundary)
            let result = try parser.parse(request.body)
            guard let filePart = result.filePart else {
                return HostHTTPResponse.text("file missing", status: .badRequest)
            }
            let response = try await ocr.performOCR(payload: .data(filePart.data, filename: filePart.filename), preferredLanguages: result.languages, timeout: 2.0)
            return HostHTTPResponse.json(response)
        } else {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            struct OCRJSONPayload: Decodable {
                let url: String?
                let languages: [String]?
                let timeoutMs: Int?
            }
            let payload = try decoder.decode(OCRJSONPayload.self, from: request.body)
            if let urlString = payload.url, let url = URL(string: urlString) {
                let response = try await ocr.performOCR(
                    payload: .fileURL(url),
                    preferredLanguages: payload.languages ?? [],
                    timeout: TimeInterval(payload.timeoutMs ?? 2000) / 1000.0
                )
                return HostHTTPResponse.json(response)
            } else {
                return HostHTTPResponse.text("invalid payload", status: .badRequest)
            }
        }
    }

    private func ocrHealth() async throws -> HostHTTPResponse {
        guard await isModuleEnabled(.ocr) else {
            return HostHTTPResponse.text("module disabled", status: .conflict)
        }
        let health = await ocr.health()
        return HostHTTPResponse.json(health)
    }

    private func createWatch(body: Data) async throws -> HostHTTPResponse {
        guard await isModuleEnabled(.fswatch) else {
            return HostHTTPResponse.text("module disabled", status: .conflict)
        }
        let request = try JSONDecoder().decode(FileWatchRegistrationRequest.self, from: body)
        let info = try await fswatch.registerWatch(request)
        try await moduleManager.updateConfiguration { config in
            if !config.modules.fswatch.enabled {
                config.modules.fswatch.enabled = true
            }
            var watches = config.modules.fswatch.config.watches
            let descriptor = HostAgentConfiguration.FSWatchConfig.WatchDescriptor(
                id: info.id,
                path: info.path,
                glob: info.glob,
                target: info.target,
                handoff: info.handoff
            )
            watches.append(descriptor)
            config.modules.fswatch.config.watches = watches
        }
        let updatedConfig = await moduleManager.configuration()
        await fswatch.updateConfiguration(updatedConfig.modules.fswatch.config)
        return HostHTTPResponse.json(info, status: .created)
    }

    private func listWatches() async throws -> HostHTTPResponse {
        guard await isModuleEnabled(.fswatch) else {
            return HostHTTPResponse.text("module disabled", status: .conflict)
        }
        let watches = await fswatch.listWatches()
        return HostHTTPResponse.json(["watches": watches])
    }

    private func deleteWatch(path: String) async throws -> HostHTTPResponse {
        guard await isModuleEnabled(.fswatch) else {
            return HostHTTPResponse.text("module disabled", status: .conflict)
        }
        guard let id = path.components(separatedBy: "/").last else {
            return HostHTTPResponse.text("invalid id", status: .badRequest)
        }
        try await fswatch.removeWatch(id: id)
        try await moduleManager.updateConfiguration { config in
            config.modules.fswatch.config.watches.removeAll { $0.id == id }
        }
        let updatedConfig = await moduleManager.configuration()
        await fswatch.updateConfiguration(updatedConfig.modules.fswatch.config)
        return HostHTTPResponse.noContent()
    }

    private func parseInterval(_ string: String) -> TimeInterval? {
        if string.hasSuffix("m"), let minutes = Double(string.dropLast()) {
            return minutes * 60
        } else if string.hasSuffix("s"), let seconds = Double(string.dropLast()) {
            return seconds
        } else if let value = Double(string) {
            return value
        }
        return nil
    }

    private func isModuleEnabled(_ kind: ModuleKind) async -> Bool {
        let config = await moduleManager.configuration()
        switch kind {
        case .imessage:
            return config.modules.imessage.enabled
        case .ocr:
            return config.modules.ocr.enabled
        case .fswatch:
            return config.modules.fswatch.enabled
        case .contacts:
            return config.modules.contacts.enabled
        case .calendar:
            return config.modules.calendar.enabled
        case .reminders:
            return config.modules.reminders.enabled
        case .mail:
            return config.modules.mail.enabled
        case .notes:
            return config.modules.notes.enabled
        case .faces:
            return config.modules.faces.enabled
        }
    }
}
