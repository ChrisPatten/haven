import XCTest
@testable import Email
@testable import HavenCore

final class EmailServiceTests: XCTestCase {
    var emailService: EmailService!
    
    override func setUp() async throws {
        try await super.setUp()
        emailService = EmailService()
    }
    
    override func tearDown() async throws {
        emailService = nil
        try await super.tearDown()
    }
    
    // MARK: - Parsing Tests
    
    func testParseReceiptEmail() async throws {
        let testBundle = Bundle.module
        guard let fixtureURL = testBundle.url(forResource: "receipt", withExtension: "emlx", subdirectory: "Fixtures") else {
            XCTFail("Could not find receipt.emlx fixture")
            return
        }
        
        let message = try await emailService.parseEmlxFile(at: fixtureURL)
        
        XCTAssertEqual(message.subject, "Test Receipt Email")
        XCTAssertEqual(message.from, ["sender@example.com"])
        XCTAssertEqual(message.to, ["recipient@example.com"])
        XCTAssertEqual(message.messageId, "<test123@example.com>")
        XCTAssertNotNil(message.bodyPlainText)
        XCTAssertTrue(message.bodyPlainText?.contains("Order Number: ORD-2025-12345") ?? false)
        XCTAssertTrue(message.bodyPlainText?.contains("$49.99") ?? false)
    }
    
    func testParseBillEmail() async throws {
        let testBundle = Bundle.module
        guard let fixtureURL = testBundle.url(forResource: "bill", withExtension: "emlx", subdirectory: "Fixtures") else {
            XCTFail("Could not find bill.emlx fixture")
            return
        }
        
        let message = try await emailService.parseEmlxFile(at: fixtureURL)
        
        XCTAssertEqual(message.subject, "Your Monthly Bill is Ready")
        XCTAssertEqual(message.from, ["billing@utility.com"])
        XCTAssertEqual(message.to, ["customer@example.com"])
        XCTAssertNotNil(message.bodyPlainText)
        XCTAssertTrue(message.bodyPlainText?.contains("$125.50") ?? false)
    }
    
    func testParsePromotionalEmail() async throws {
        let testBundle = Bundle.module
        guard let fixtureURL = testBundle.url(forResource: "promotional", withExtension: "emlx", subdirectory: "Fixtures") else {
            XCTFail("Could not find promotional.emlx fixture")
            return
        }
        
        let message = try await emailService.parseEmlxFile(at: fixtureURL)
        
        XCTAssertEqual(message.subject, "Weekly Newsletter - 50% Off Sale!")
        XCTAssertEqual(message.listUnsubscribe, "<mailto:unsubscribe@newsletter.com>")
        XCTAssertNotNil(message.bodyHTML)
    }
    
    func testParseAppointmentEmail() async throws {
        let testBundle = Bundle.module
        guard let fixtureURL = testBundle.url(forResource: "appointment", withExtension: "emlx", subdirectory: "Fixtures") else {
            XCTFail("Could not find appointment.emlx fixture")
            return
        }
        
        let message = try await emailService.parseEmlxFile(at: fixtureURL)
        
        XCTAssertEqual(message.subject, "Appointment Confirmation")
        XCTAssertEqual(message.inReplyTo, "<req100@example.com>")
        XCTAssertEqual(message.references, ["<req100@example.com>"])
        XCTAssertNotNil(message.bodyPlainText)
    }
    
    func testRealFixturesExposeMessageIDs() async throws {
        let fileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = fileURL
            .deletingLastPathComponent() // EmailTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // hostagent
            .deletingLastPathComponent() // repo root
        let fixturesRoot = repoRoot.appendingPathComponent("tests/fixtures/email", isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: fixturesRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var missingIDs: [String] = []
        var parsedCount = 0
        var missingDetails: [(String, [String])] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "emlx" else {
                continue
            }
            let message = try await emailService.parseEmlxFile(at: url)
            parsedCount += 1
            if message.messageId == nil || message.messageId?.isEmpty == true {
                missingIDs.append(url.path)
                missingDetails.append((url.lastPathComponent, Array(message.headers.keys.sorted())))
            }
        }
        XCTAssertEqual(parsedCount, 20, "Expected to parse 20 .emlx fixtures")
        XCTAssertTrue(
            missingIDs.isEmpty,
            "Missing Message-ID for fixtures: \(missingIDs). Headers: \(missingDetails)"
        )
    }
    
    func testParseNonExistentFile() async {
        let nonExistentURL = URL(fileURLWithPath: "/tmp/nonexistent.emlx")
        
        do {
            _ = try await emailService.parseEmlxFile(at: nonExistentURL)
            XCTFail("Should have thrown an error")
        } catch {
            XCTAssertTrue(error is EmailServiceError)
            if case EmailServiceError.fileNotFound = error {
                // Expected
            } else {
                XCTFail("Expected fileNotFound error")
            }
        }
    }
    
    // MARK: - Metadata Extraction Tests
    
    func testExtractMetadata() async throws {
        let message = EmailMessage(
            messageId: "<test@example.com>",
            subject: "Test Subject",
            from: ["sender@example.com"],
            to: ["recipient@example.com"],
            date: Date(),
            bodyPlainText: "This is a test email body with some content."
        )
        
        let metadata = await emailService.extractEmailMetadata(from: message)
        
        XCTAssertEqual(metadata.subject, "Test Subject")
        XCTAssertEqual(metadata.from, ["sender@example.com"])
        XCTAssertEqual(metadata.to, ["recipient@example.com"])
        XCTAssertNotNil(metadata.bodyPreview)
        XCTAssertFalse(metadata.hasAttachments)
        XCTAssertEqual(metadata.attachmentCount, 0)
    }
    
    func testMetadataWithAttachments() async {
        let message = EmailMessage(
            subject: "Email with attachment",
            from: ["sender@example.com"],
            to: ["recipient@example.com"],
            attachments: [
                EmailAttachment(filename: "document.pdf", mimeType: "application/pdf", partIndex: 0)
            ]
        )
        
        let metadata = await emailService.extractEmailMetadata(from: message)
        
        XCTAssertTrue(metadata.hasAttachments)
        XCTAssertEqual(metadata.attachmentCount, 1)
    }
    
    // MARK: - Noise Detection Tests
    
    func testIsNoiseEmailWithListUnsubscribe() async {
        let metadata = EmailMetadata(
            subject: "Newsletter",
            from: ["newsletter@example.com"],
            listUnsubscribe: "<mailto:unsubscribe@example.com>"
        )
        
        let isNoise = await emailService.isNoiseEmail(metadata: metadata)
        XCTAssertTrue(isNoise)
    }
    
    func testIsNoiseEmailWithPromotionalKeywords() async {
        let metadata = EmailMetadata(
            subject: "Special Sale - 50% Discount Today!",
            from: ["sales@example.com"]
        )
        
        let isNoise = await emailService.isNoiseEmail(metadata: metadata)
        XCTAssertTrue(isNoise)
    }
    
    func testIsNoiseEmailWithNoReplyAddress() async {
        let metadata = EmailMetadata(
            subject: "Update",
            from: ["noreply@example.com"]
        )
        
        let isNoise = await emailService.isNoiseEmail(metadata: metadata)
        XCTAssertTrue(isNoise)
    }
    
    func testIsNotNoiseEmailPersonal() async {
        let metadata = EmailMetadata(
            subject: "Hello from a friend",
            from: ["friend@example.com"]
        )
        
        let isNoise = await emailService.isNoiseEmail(metadata: metadata)
        XCTAssertFalse(isNoise)
    }
    
    // MARK: - Intent Classification Tests
    
    func testClassifyIntentBill() async {
        let classification = await emailService.classifyIntent(
            subject: "Your Monthly Bill",
            body: "Please pay your invoice of $100",
            sender: "billing@utility.com"
        )
        
        XCTAssertEqual(classification.primaryIntent, .bill)
        XCTAssertGreaterThan(classification.confidence, 0.7)
    }
    
    func testClassifyIntentReceipt() async {
        let classification = await emailService.classifyIntent(
            subject: "Your Receipt",
            body: "Thank you for your purchase",
            sender: "orders@store.com"
        )
        
        XCTAssertEqual(classification.primaryIntent, .receipt)
        XCTAssertGreaterThan(classification.confidence, 0.7)
    }
    
    func testClassifyIntentOrderConfirmation() async {
        let classification = await emailService.classifyIntent(
            subject: "Order Confirmation #12345",
            body: "Your order has been confirmed and will ship soon",
            sender: "orders@store.com"
        )
        
        XCTAssertEqual(classification.primaryIntent, .orderConfirmation)
        XCTAssertGreaterThan(classification.confidence, 0.7)
    }
    
    func testClassifyIntentAppointment() async {
        let classification = await emailService.classifyIntent(
            subject: "Appointment Reminder",
            body: "Your appointment is scheduled for tomorrow",
            sender: "calendar@clinic.com"
        )
        
        XCTAssertEqual(classification.primaryIntent, .appointment)
        XCTAssertGreaterThan(classification.confidence, 0.7)
    }
    
    func testClassifyIntentActionRequired() async {
        let classification = await emailService.classifyIntent(
            subject: "Action Required: Please Respond",
            body: "We need your immediate attention",
            sender: "support@example.com"
        )
        
        XCTAssertEqual(classification.primaryIntent, .actionRequired)
        XCTAssertGreaterThanOrEqual(classification.confidence, 0.7)
    }
    
    func testClassifyIntentPromotional() async {
        let classification = await emailService.classifyIntent(
            subject: "Limited Time Sale!",
            body: "Get 50% off everything today",
            sender: "marketing@store.com"
        )
        
        XCTAssertEqual(classification.primaryIntent, .promotional)
        XCTAssertGreaterThan(classification.confidence, 0.7)
    }
    
    // MARK: - PII Redaction Tests
    
    func testRedactEmailAddresses() async {
        let text = "Contact me at john.doe@example.com or jane@company.org"
        let redacted = await emailService.redactPII(in: text)
        
        XCTAssertFalse(redacted.contains("john.doe@example.com"))
        XCTAssertFalse(redacted.contains("jane@company.org"))
        XCTAssertTrue(redacted.contains("[EMAIL_REDACTED]"))
    }
    
    func testRedactPhoneNumbers() async {
        let text = "Call us at 555-123-4567 or (555) 987-6543"
        let redacted = await emailService.redactPII(in: text)
        
        XCTAssertFalse(redacted.contains("555-123-4567"))
        XCTAssertFalse(redacted.contains("(555) 987-6543"))
        XCTAssertTrue(redacted.contains("[PHONE_REDACTED]"))
    }
    
    func testRedactAccountNumbers() async {
        let text = "Your account number is 98765432"
        let redacted = await emailService.redactPII(in: text)
        
        XCTAssertFalse(redacted.contains("98765432"))
        XCTAssertTrue(redacted.contains("[ACCOUNT_REDACTED]"))
    }
    
    func testRedactSSN() async {
        let text = "SSN: 123-45-6789"
        let redacted = await emailService.redactPII(in: text)
        
        XCTAssertFalse(redacted.contains("123-45-6789"))
        XCTAssertTrue(redacted.contains("[SSN_REDACTED]"))
    }
    
    func testRedactMultiplePII() async {
        let text = """
        Contact: john@example.com
        Phone: 555-123-4567
        Account: 12345678
        SSN: 123-45-6789
        """
        
        let redacted = await emailService.redactPII(in: text)
        
        XCTAssertFalse(redacted.contains("john@example.com"))
        XCTAssertFalse(redacted.contains("555-123-4567"))
        XCTAssertFalse(redacted.contains("12345678"))
        XCTAssertFalse(redacted.contains("123-45-6789"))
        
        XCTAssertTrue(redacted.contains("[EMAIL_REDACTED]"))
        XCTAssertTrue(redacted.contains("[PHONE_REDACTED]"))
        XCTAssertTrue(redacted.contains("[ACCOUNT_REDACTED]"))
        XCTAssertTrue(redacted.contains("[SSN_REDACTED]"))
    }
}
