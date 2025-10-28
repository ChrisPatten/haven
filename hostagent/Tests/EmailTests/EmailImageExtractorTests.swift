import XCTest
@testable import Email
@testable import HavenCore
@testable import OCR

final class EmailImageExtractorTests: XCTestCase {
    var imageExtractor: EmailImageExtractor!
    var mockOCRService: OCRServiceProtocol!
    
    override func setUp() async throws {
        try await super.setUp()
        imageExtractor = EmailImageExtractor()
        mockOCRService = MockOCRService() as OCRServiceProtocol
    }
    
    override func tearDown() async throws {
        imageExtractor = nil
        mockOCRService = nil
        try await super.tearDown()
    }
    
    // MARK: - Test Helper Methods
    
    private func loadFixture(_ name: String) async throws -> EmailMessage {
        let testBundle = Bundle.module
        guard let fixtureURL = testBundle.url(forResource: name, withExtension: "emlx", subdirectory: "Fixtures/body-extraction") else {
            throw TestError.fixtureNotFound(name)
        }
        
        let emailService = EmailService()
        return try await emailService.parseEmlxFile(at: fixtureURL)
    }
    
    private func loadExpectedCaptions(_ name: String) throws -> [String] {
        let testBundle = Bundle.module
        guard let captionsURL = testBundle.url(forResource: name, withExtension: "captions.json", subdirectory: "Fixtures/body-extraction") else {
            throw TestError.goldenRecordNotFound(name)
        }
        
        let data = try Data(contentsOf: captionsURL)
        return try JSONDecoder().decode([String].self, from: data)
    }
    
    private func assertCaptionsMatch(fixture: String) async throws {
        let email = try await loadFixture(fixture)
        let captions = await imageExtractor.extractImageCaptions(
            from: email,
            attachments: email.attachments,
            ocrService: mockOCRService
        )
        let expectedCaptions = try loadExpectedCaptions(fixture)
        
        XCTAssertEqual(Set(captions), Set(expectedCaptions), 
                      "Image captions don't match expected for fixture: \(fixture)")
    }
    
    // MARK: - HTML Caption Extraction Tests
    
    func testExtractAltTextFromImages() async {
        let html = """
        <html>
        <body>
        <img src="image1.jpg" alt="Product Launch Image">
        <img src="image2.png" alt="Company Logo">
        <img src="image3.gif" title="Banner Ad">
        </body>
        </html>
        """
        
        let email = EmailMessage(bodyHTML: html)
        let captions = await imageExtractor.extractImageCaptions(
            from: email,
            attachments: [],
            ocrService: nil
        )
        
        XCTAssertTrue(captions.contains("Product Launch Image"))
        XCTAssertTrue(captions.contains("Company Logo"))
        XCTAssertTrue(captions.contains("Banner Ad"))
    }
    
    func testExtractFigcaption() async {
        let html = """
        <html>
        <body>
        <figure>
        <img src="chart.png" alt="Sales Chart">
        <figcaption>Q3 Sales Performance - Up 25% from last quarter</figcaption>
        </figure>
        
        <figure>
        <img src="photo.jpg">
        <figcaption>Team photo from our annual retreat</figcaption>
        </figure>
        </body>
        </html>
        """
        
        let email = EmailMessage(bodyHTML: html)
        let captions = await imageExtractor.extractImageCaptions(
            from: email,
            attachments: [],
            ocrService: nil
        )
        
        XCTAssertTrue(captions.contains("Sales Chart"))
        XCTAssertTrue(captions.contains("Q3 Sales Performance - Up 25% from last quarter"))
        XCTAssertTrue(captions.contains("Team photo from our annual retreat"))
    }
    
    func testExtractAdjacentText() async {
        let html = """
        <html>
        <body>
        <p>Here's our latest product:</p>
        <img src="product.jpg" alt="New Product">
        <p>This revolutionary device will change everything you know about technology.</p>
        
        <div>
        <img src="team.jpg">
        <p>Our amazing development team working hard to bring you the best products.</p>
        </div>
        </body>
        </html>
        """
        
        let email = EmailMessage(bodyHTML: html)
        let captions = await imageExtractor.extractImageCaptions(
            from: email,
            attachments: [],
            ocrService: nil
        )
        
        XCTAssertTrue(captions.contains("New Product"))
        XCTAssertTrue(captions.contains("This revolutionary device will change everything you know about technology"))
        XCTAssertTrue(captions.contains("Our amazing development team working hard to bring you the best products"))
    }
    
    func testExtractFromDataURI() async {
        // Mock OCR service to return test text
        (mockOCRService as! MockOCRService).mockOCRResult = OCRResult(
            ocrText: "Extracted text from embedded image",
            ocrBoxes: [],
            regions: nil,
            detectedLanguages: nil,
            recognitionLevel: "fast",
            lang: "en",
            tooling: [:],
            timingsMs: [:]
        )
        
        let html = """
        <html>
        <body>
        <img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==" alt="Embedded Image">
        </body>
        </html>
        """
        
        let email = EmailMessage(bodyHTML: html)
        let captions = await imageExtractor.extractImageCaptions(
            from: email,
            attachments: [],
            ocrService: mockOCRService
        )
        
        XCTAssertTrue(captions.contains("Embedded Image"))
        XCTAssertTrue(captions.contains("Extracted text from embedded image"))
    }
    
    func testFilterEmptyCaptions() async {
        let html = """
        <html>
        <body>
        <img src="image1.jpg" alt="">
        <img src="image2.jpg" alt="Valid Caption">
        <img src="image3.jpg">
        <figure>
        <img src="image4.jpg">
        <figcaption></figcaption>
        </figure>
        </body>
        </html>
        """
        
        let email = EmailMessage(bodyHTML: html)
        let captions = await imageExtractor.extractImageCaptions(
            from: email,
            attachments: [],
            ocrService: nil
        )
        
        XCTAssertEqual(captions.count, 1)
        XCTAssertTrue(captions.contains("Valid Caption"))
    }
    
    func testRemoveDuplicateCaptions() async {
        let html = """
        <html>
        <body>
        <img src="image1.jpg" alt="Same Caption">
        <img src="image2.jpg" alt="Same Caption">
        <img src="image3.jpg" alt="Different Caption">
        </body>
        </html>
        """
        
        let email = EmailMessage(bodyHTML: html)
        let captions = await imageExtractor.extractImageCaptions(
            from: email,
            attachments: [],
            ocrService: nil
        )
        
        XCTAssertEqual(captions.count, 2)
        XCTAssertTrue(captions.contains("Same Caption"))
        XCTAssertTrue(captions.contains("Different Caption"))
    }
    
    // MARK: - Golden Record Tests
    
    func testHTMLWithImagesGoldenRecord() async throws {
        try await assertCaptionsMatch(fixture: "html-with-images")
    }
    
    // MARK: - Edge Cases
    
    func testNoHTMLContent() async {
        let email = EmailMessage(bodyPlainText: "Plain text email with no images")
        let captions = await imageExtractor.extractImageCaptions(
            from: email,
            attachments: [],
            ocrService: nil
        )
        
        XCTAssertTrue(captions.isEmpty)
    }
    
    func testMalformedHTML() async {
        let malformedHTML = "<html><body><img src=\"image.jpg\" alt=\"Test Caption\"</body>"
        let email = EmailMessage(bodyHTML: malformedHTML)
        let captions = await imageExtractor.extractImageCaptions(
            from: email,
            attachments: [],
            ocrService: nil
        )
        
        // Should still extract captions even with malformed HTML
        XCTAssertTrue(captions.contains("Test Caption"))
    }
    
    func testImageAttachments() async {
        let attachments = [
            EmailAttachment(filename: "photo.jpg", mimeType: "image/jpeg", contentId: nil, size: 1024, partIndex: 1),
            EmailAttachment(filename: "document.pdf", mimeType: "application/pdf", contentId: nil, size: 2048, partIndex: 2),
            EmailAttachment(filename: "chart.png", mimeType: "image/png", contentId: nil, size: 512, partIndex: 3)
        ]
        
        let email = EmailMessage(attachments: attachments)
        let captions = await imageExtractor.extractImageCaptions(
            from: email,
            attachments: attachments,
            ocrService: nil
        )
        
        // Should not extract captions from attachments without OCR service
        XCTAssertTrue(captions.isEmpty)
    }
}

// MARK: - Mock OCR Service

class MockOCRService: OCRServiceProtocol {
    var mockOCRResult: OCRResult?
    
    func processImage(path: String? = nil, data: Data? = nil, recognitionLevel: String? = nil, includeLayout: Bool? = nil) async throws -> OCRResult {
        if let mockResult = mockOCRResult {
            return mockResult
        }
        
        return OCRResult(
            ocrText: "",
            ocrBoxes: [],
            regions: nil,
            detectedLanguages: nil,
            recognitionLevel: "fast",
            lang: "en",
            tooling: [:],
            timingsMs: [:]
        )
    }
}
