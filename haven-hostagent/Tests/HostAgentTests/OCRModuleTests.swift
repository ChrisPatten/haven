import XCTest
@testable import Core
@testable import OCR

#if os(macOS)
import AppKit
#endif

final class OCRModuleTests: XCTestCase {
    func testVisionOCRDetectsTextOnGeneratedImage() async throws {
        #if os(macOS)
        let config = HostAgentConfiguration.OCRConfig(languages: ["en"], timeoutMilliseconds: 2_000)
        let module = OCRModule(configuration: config)
        let gateway = NullGateway()
        let context = ModuleContext(
            configuration: HostAgentConfiguration(),
            moduleConfigPath: nil,
            stateDirectory: FileManager.default.temporaryDirectory,
            tmpDirectory: FileManager.default.temporaryDirectory,
            gatewayClient: gateway
        )
        try await module.boot(context: context)

        let imageURL = try createImageWithText("Haven")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let response = try await module.performOCR(
            payload: .fileURL(imageURL),
            preferredLanguages: ["en"],
            timeout: 2.0
        )

        XCTAssertTrue(response.ocrText.lowercased().contains("haven"), "Expected OCR text to contain 'Haven' but got \(response.ocrText)")
        #else
        throw XCTSkip("Vision OCR tests require macOS")
        #endif
    }

    #if os(macOS)
    private func createImageWithText(_ text: String) throws -> URL {
        let size = NSSize(width: 400, height: 160)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 72, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let point = NSPoint(x: (size.width - textSize.width) / 2.0, y: (size.height - textSize.height) / 2.0)
        attributed.draw(at: point)
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to render PNG")
            throw TestError.imageEncodingFailed
        }

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-test-\(UUID().uuidString).png")
        try png.write(to: outputURL)
        return outputURL
    }
    #endif
}

private struct NullGateway: GatewayTransport {
    func ingest<Event: Encodable>(events: [Event]) async throws {}
    func requestPresignedPut(path: String, sha256: String, size: Int64) async throws -> URL { URL(string: "https://example.com")! }
    func notifyFileIngested(_ event: FileIngestEvent) async throws {}
    func upload(fileData: Data, to url: URL) async throws {}
}

enum TestError: Error {
    case imageEncodingFailed
}
