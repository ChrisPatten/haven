import Foundation
import Logging
@preconcurrency import Vision
import AppKit
import Core

public final class OCRModule: OCRService {
    public let kind: ModuleKind = .ocr
    public let logger = Logger(label: "HostAgent.OCR")
    private var configuration: HostAgentConfiguration.OCRConfig
    private var isBooted = false
    private let queue = DispatchQueue(label: "hostagent.ocr", qos: .userInitiated)

    public init(configuration: HostAgentConfiguration.OCRConfig) {
        self.configuration = configuration
    }

    public func boot(context: ModuleContext) async throws {
        guard !isBooted else { return }
        // Warm up by running a trivial request to load models lazily
        try await warmup()
        isBooted = true
    }

    public func shutdown() async {
        isBooted = false
    }

    public func summary() async -> ModuleSummary {
        ModuleSummary(kind: kind, enabled: true, status: isBooted ? "ready" : "initializing")
    }

    public func performOCR(payload: OCRRequest.Payload, preferredLanguages: [String], timeout: TimeInterval) async throws -> OCRResponseBody {
        let languages = preferredLanguages.isEmpty ? configuration.languages : preferredLanguages
        let payloadData: Data
        let imageURL: URL?

        switch payload {
        case .data(let data, _):
            payloadData = data
            imageURL = nil
        case .fileURL(let url):
            payloadData = try Data(contentsOf: url)
            imageURL = url
        }

        let handler = try makeRequestHandler(data: payloadData, url: imageURL)
        let startDate = Date()
        let lines = try await recognize(handler: handler, languages: languages, timeout: timeout)
        let total = Int(Date().timeIntervalSince(startDate) * 1000)
        let text = lines.map(\.text).joined(separator: "\n")
        let boxes: [OCRBox] = lines.map { line in
            OCRBox(text: line.text, bbox: line.bbox, level: "line")
        }

        return OCRResponseBody(
            ocrText: text,
            ocrBoxes: boxes,
            lang: languages.first ?? "en",
            tooling: ["vision": "macOS-\(ProcessInfo.processInfo.operatingSystemVersionString)"],
            timingsMs: ["total": total],
            error: nil
        )
    }

    public func health() async -> [String: String] {
        [
            "status": isBooted ? "ready" : "initializing",
            "languages": configuration.languages.joined(separator: ",")
        ]
    }

    public func updateConfiguration(_ config: HostAgentConfiguration.OCRConfig) async {
        configuration = config
    }

    private func warmup() async throws {
        let dummy = Data(count: 0)
        _ = dummy
    }

    private func makeRequestHandler(data: Data, url: URL?) throws -> VNImageRequestHandler {
        if let url {
            return VNImageRequestHandler(url: url)
        } else if let image = NSImage(data: data), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return VNImageRequestHandler(cgImage: cgImage, options: [:])
        } else if let cgImage = CGImage.createPNG(data: data) {
            return VNImageRequestHandler(cgImage: cgImage, options: [:])
        } else {
            throw NSError(domain: "HostAgent.OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported image data"])
        }
    }

    private func recognize(handler: VNImageRequestHandler, languages: [String], timeout: TimeInterval) async throws -> [RecognizedLine] {
        try await withThrowingTaskGroup(of: [RecognizedLine].self) { group in
            let queue = self.queue
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async {
                        do {
                            let request = VNRecognizeTextRequest { request, error in
                                if let error {
                                    continuation.resume(throwing: error)
                                } else {
                                    let observations = request.results as? [VNRecognizedTextObservation] ?? []
                                    let lines = observations.map { observation -> RecognizedLine in
                                        let bbox = [
                                            Double(observation.boundingBox.origin.x),
                                            Double(observation.boundingBox.origin.y),
                                            Double(observation.boundingBox.size.width),
                                            Double(observation.boundingBox.size.height)
                                        ]
                                        return RecognizedLine(text: observation.topCandidates(1).first?.string ?? "", bbox: bbox)
                                    }
                                    continuation.resume(returning: lines)
                                }
                            }
                            request.recognitionLanguages = languages
                            request.recognitionLevel = .accurate
                            try handler.perform([request])
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TimeoutError()
            }

            guard let result = try await group.next() else {
                throw TimeoutError()
            }
            group.cancelAll()
            return result
        }
    }
}

private struct RecognizedLine: Sendable {
    let text: String
    let bbox: [Double]
}

extension OCRModule: @unchecked Sendable {}

private extension CGImage {
    static func createPNG(data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData), let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return nil
        }
        return image
    }
}
