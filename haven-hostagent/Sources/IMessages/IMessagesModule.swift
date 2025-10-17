import Core
import Foundation
import Logging

public actor IMessagesModule: IMessagesService {
    public let kind: ModuleKind = .imessage
    public let logger = Logger(label: "HostAgent.IMessages")

    private var configuration: HostAgentConfiguration.IMessagesConfig
    private let ocr: OCRService
    private let gateway: GatewayTransport
    private let stateStore: JSONStateStore<IMessagesState>
    private var state: IMessagesState
    private var isBooted = false
    private let logBuffer = LogBuffer(capacity: 500)
    private let backgroundQueue = DispatchQueue(label: "hostagent.imessage", qos: .userInitiated)
    private var ocrLanguages: [String]

    public init(
        configuration: HostAgentConfiguration.IMessagesConfig,
        ocr: OCRService,
        gateway: GatewayTransport,
        stateURL: URL,
        ocrLanguages: [String]
    ) {
        self.configuration = configuration
        self.ocr = ocr
        self.gateway = gateway
        self.stateStore = JSONStateStore(url: stateURL)
        self.state = self.stateStore.load()
        self.ocrLanguages = ocrLanguages
    }

    public func boot(context: ModuleContext) async throws {
        guard !isBooted else { return }
        try HostAgentPaths.prepare()
        do {
            try await refreshHeadRowID()
            isBooted = true
            logger.info("iMessage module booted", metadata: ["cursor": "\(state.cursorRowID)", "head": "\(state.headRowID)"])
        } catch {
            state.lastError = "\(error)"
            stateStore.save(state)
            throw error
        }
    }

    public func shutdown() async {
        stateStore.save(state)
        isBooted = false
    }

    public func summary() async -> ModuleSummary {
        ModuleSummary(
            kind: kind,
            enabled: isBooted,
            status: isBooted ? "ready" : "initializing",
            lastError: state.lastError,
            extra: [
                "cursor_rowid": "\(state.cursorRowID)",
                "head_rowid": "\(state.headRowID)",
                "floor_rowid": "\(state.floorRowID)"
            ]
        )
    }

    public func run(request: IMessagesRunRequest) async throws -> IMessagesRunResponse {
        guard isBooted else {
            throw NSError(domain: "HostAgent.IMessages", code: 1, userInfo: [NSLocalizedDescriptionKey: "Module not booted"])
        }
        let batchSize = request.batchSize ?? configuration.batchSize
        let maxRows = request.maxRows ?? configuration.backfillMaxRows
        return try await processBatch(mode: request.mode, batchSize: batchSize, maxRows: maxRows)
    }

    public func state() async -> IMessagesState {
        state
    }

    public func logs(since interval: TimeInterval) async -> [IMessagesLogEntry] {
        logBuffer.entries(since: Date().addingTimeInterval(-interval))
    }

    public func updateConfiguration(_ config: HostAgentConfiguration.IMessagesConfig) async {
        configuration = config
    }

    public func updateOCRLanguages(_ languages: [String]) async {
        ocrLanguages = languages
    }

    private func refreshHeadRowID() async throws {
        let snapshot = try await runBlocking {
            try IMessagesSnapshot.createTmpSnapshot(base: HostAgentPaths.tmpDirectory)
        }
        let db = try await runBlocking {
            try IMessagesDatabase(snapshot: snapshot)
        }
        defer { snapshot.cleanup() }
        let head = try await runBlocking {
            try db.fetchHeadRowID()
        }
        state.headRowID = head
        if state.cursorRowID == 0 {
            state.cursorRowID = head
            state.floorRowID = head
        }
        stateStore.save(state)
    }

    private func processBatch(mode: IMessagesRunMode, batchSize: Int, maxRows: Int?) async throws -> IMessagesRunResponse {
        let clock = ContinuousClock()
        let start = clock.now

        let snapshot = try await runBlocking {
            try IMessagesSnapshot.createTmpSnapshot(base: HostAgentPaths.tmpDirectory)
        }

        let db = try await runBlocking {
            try IMessagesDatabase(snapshot: snapshot)
        }
        defer { snapshot.cleanup() }

        let head = try await runBlocking { try db.fetchHeadRowID() }
        state.headRowID = head
        if state.cursorRowID == 0 {
            let floor = try await runBlocking { try db.fetchFloorRowID() }
            state.cursorRowID = floor
            state.floorRowID = floor
        }

        let rows = try await runBlocking {
            try db.fetchMessages(after: self.state.cursorRowID, limit: batchSize, maxRow: maxRows)
        }

        guard !rows.isEmpty else {
            state.lastRun = Date()
            stateStore.save(state)
            logBuffer.append(level: "info", message: "No new messages to process", metadata: [:])
            return IMessagesRunResponse(
                processed: 0,
                attachments: 0,
                cursorRowID: state.cursorRowID,
                headRowID: state.headRowID,
                durationMs: 0
            )
        }

        let events = try await buildEvents(from: rows)
        try await gateway.ingest(events: events)

        if let last = rows.last {
            state.cursorRowID = last.rowID
        }
        state.lastRun = Date()
        state.lastError = nil
        stateStore.save(state)

        let duration = Int(start.duration(to: clock.now).components.seconds * 1000)
        logBuffer.append(level: "info", message: "Batch processed \(rows.count) messages", metadata: ["duration_ms": "\(duration)"])

        return IMessagesRunResponse(
            processed: rows.count,
            attachments: rows.reduce(0) { $0 + $1.attachments.count },
            cursorRowID: state.cursorRowID,
            headRowID: state.headRowID,
            durationMs: duration
        )
    }

    private func buildEvents(from rows: [IMessagesRow]) async throws -> [IMessagesEvent] {
        var events: [IMessagesEvent] = []
        for row in rows {
            var chunks: [IMessagesEvent.EventChunk] = []
            if let text = row.normalizedBody, !text.isEmpty {
                let chunkID = Hashing.sha256Hex("\(row.rowID):text:\(text)")
                chunks.append(.init(chunkID: chunkID, type: "text", text: text, meta: nil))
            }

            var attachmentMetas: [IMessagesEvent.MessageMetadata.Attachment] = []
            for attachment in row.attachments {
                var meta = IMessagesEvent.MessageMetadata.Attachment(
                    id: attachment.id,
                    uti: attachment.uti,
                    path: attachment.originalPath,
                    sha256: attachment.sha256,
                    status: attachment.resolvedURL == nil ? "missing" : "available",
                    ocrStatus: nil,
                    error: nil
                )

                guard attachment.isImage else {
                    meta.ocrStatus = "skipped"
                    attachmentMetas.append(meta)
                    continue
                }

                guard configuration.ocrEnabled else {
                    meta.ocrStatus = "disabled"
                    attachmentMetas.append(meta)
                    continue
                }

                guard let url = attachment.resolvedURL else {
                    meta.ocrStatus = "missing"
                    attachmentMetas.append(meta)
                    continue
                }

                do {
                    let ocrResponse = try await ocr.performOCR(
                        payload: .fileURL(url),
                        preferredLanguages: ocrLanguages,
                        timeout: Double(configuration.timeoutSeconds)
                    )
                    let chunkID = Hashing.sha256Hex("\(row.rowID):attachment:\(attachment.id):ocr")
                    var chunkMeta: [String: String] = [
                        "attachment_id": attachment.id
                    ]
                    if let boxesData = try? JSONEncoder().encode(ocrResponse.ocrBoxes), let boxes = String(data: boxesData, encoding: .utf8) {
                        chunkMeta["boxes"] = boxes
                    }
                    chunkMeta["lang"] = ocrResponse.lang
                    chunks.append(
                        IMessagesEvent.EventChunk(
                            chunkID: chunkID,
                            type: "image_ocr",
                            text: ocrResponse.ocrText,
                            meta: chunkMeta
                        )
                    )
                    meta.ocrStatus = "complete"
                } catch {
                    meta.ocrStatus = "error"
                    meta.error = "\(error)"
                    logBuffer.append(level: "warn", message: "OCR failed for attachment", metadata: ["attachment_id": attachment.id, "error": "\(error)"])
                }
                attachmentMetas.append(meta)
            }

            let event = IMessagesEvent(
                sourceType: "imessage",
                sourceID: "\(row.chatGUID):\(row.rowID)",
                content: row.normalizedBody ?? "",
                chunks: chunks,
                metadata: .init(
                    thread: .init(chatGUID: row.chatGUID, participants: row.participants, service: row.service),
                    message: .init(
                        rowid: row.rowID,
                        date: DateUtils.isoString(from: row.date),
                        isFromMe: row.isFromMe,
                        handle: .init(id: row.handleID, phone: row.handlePhone, email: row.handleEmail),
                        attachments: attachmentMetas
                    )
                )
            )
            events.append(event)
        }
        return events
    }

    private func runBlocking<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            backgroundQueue.async {
                do {
                    let value = try work()
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

final class LogBuffer {
    private let capacity: Int
    private var entries: [IMessagesLogEntry] = []
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
    }

    func append(level: String, message: String, metadata: [String: String]) {
        lock.lock()
        entries.append(IMessagesLogEntry(timestamp: Date(), level: level, message: message, metadata: metadata))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
    }

    func entries(since date: Date) -> [IMessagesLogEntry] {
        lock.lock()
        let result = entries.filter { $0.timestamp >= date }
        lock.unlock()
        return result
    }
}
