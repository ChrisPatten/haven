import XCTest
@testable import Email
@testable import HavenCore

final class EmailBodyExtractorTests: XCTestCase {
    var bodyExtractor: EmailBodyExtractor!
    
    override func setUp() async throws {
        try await super.setUp()
        bodyExtractor = EmailBodyExtractor()
    }
    
    override func tearDown() async throws {
        bodyExtractor = nil
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
    
    private func loadGoldenRecord(_ name: String) throws -> String {
        let testBundle = Bundle.module
        guard let goldenURL = testBundle.url(forResource: name, withExtension: "golden.txt", subdirectory: "Fixtures/body-extraction") else {
            throw TestError.goldenRecordNotFound(name)
        }
        
        return try String(contentsOf: goldenURL)
    }
    
    private func assertCleanBodyMatches(fixture: String) async throws {
        let email = try await loadFixture(fixture)
        let cleanBody = await bodyExtractor.extractCleanBody(from: email)
        let expectedBody = try loadGoldenRecord(fixture)
        
        XCTAssertEqual(cleanBody.trimmingCharacters(in: .whitespacesAndNewlines),
                      expectedBody.trimmingCharacters(in: .whitespacesAndNewlines),
                      "Cleaned body doesn't match golden record for fixture: \(fixture)")
    }
    
    // MARK: - HTML to Markdown Tests
    
    func testHTMLToMarkdownConversion() async {
        let html = """
        <html>
        <body>
        <h2>Product Announcement</h2>
        <p>We're excited to announce our new product line!</p>
        <ul>
        <li>Advanced technology</li>
        <li>User-friendly interface</li>
        </ul>
        <p>Visit our <a href="https://example.com">website</a> for more information.</p>
        </body>
        </html>
        """
        
        let email = EmailMessage(bodyHTML: html)
        let result = await bodyExtractor.extractCleanBody(from: email)
        
        XCTAssertTrue(result.contains("Product Announcement"))
        XCTAssertTrue(result.contains("We're excited to announce our new product line!"))
        XCTAssertTrue(result.contains("Advanced technology"))
        XCTAssertTrue(result.contains("User-friendly interface"))
        // Links should be in markdown format: [text](url)
        XCTAssertTrue(result.contains("[website](https://example.com)"))
        XCTAssertFalse(result.contains("<"))
        XCTAssertFalse(result.contains(">"))
    }
    
    func testHTMLWithEntities() async {
        let html = """
        <p>This is a test with &nbsp; spaces and &lt;brackets&gt; and &amp; symbols.</p>
        """
        
        let email = EmailMessage(bodyHTML: html)
        let result = await bodyExtractor.extractCleanBody(from: email)
        
        // Verify that HTML entities are properly decoded by HTMLEntities package
        XCTAssertTrue(result.contains("This is a test with") && result.contains("spaces and <brackets> and & symbols"))
        XCTAssertFalse(result.contains("&nbsp;"))
        XCTAssertFalse(result.contains("&lt;"))
        XCTAssertFalse(result.contains("&gt;"))
        XCTAssertFalse(result.contains("&amp;"))
        
        // Verify that entities are decoded to their character equivalents
        XCTAssertTrue(result.contains("<"))
        XCTAssertTrue(result.contains(">"))
        XCTAssertTrue(result.contains("&"))
    }
    
    // MARK: - Quoted Content Tests
    
    func testStripQuotedContent() async {
        let text = """
        Thanks for your message!

        I'll get back to you soon.

        Best regards,
        John

        > On Oct 20, 2025, at 2:30 PM, Jane Doe <jane@example.com> wrote:
        > 
        > Hi John,
        > 
        > I wanted to follow up on our conversation about the project.
        > 
        > Can you please provide an update?
        > 
        > Thanks,
        > Jane
        """
        
        let email = EmailMessage(bodyPlainText: text)
        let result = await bodyExtractor.extractCleanBody(from: email)
        
        XCTAssertTrue(result.contains("Thanks for your message!"))
        XCTAssertTrue(result.contains("I'll get back to you soon"))
        XCTAssertTrue(result.contains("Best regards"))
        XCTAssertTrue(result.contains("John"))
        XCTAssertFalse(result.contains("On Oct 20, 2025"))
        XCTAssertFalse(result.contains("Jane Doe"))
        XCTAssertFalse(result.contains("I wanted to follow up"))
    }
    
    func testStripHTMLBlockquotes() async {
        let html = """
        <html>
        <body>
        <p>Thanks for your message!</p>
        <p>I'll get back to you soon.</p>
        
        <blockquote>
        <p>On Oct 20, 2025, at 2:30 PM, Jane Doe &lt;jane@example.com&gt; wrote:</p>
        <p>Hi John,</p>
        <p>I wanted to follow up on our conversation about the project.</p>
        </blockquote>
        
        <p>Best regards,<br>John</p>
        </body>
        </html>
        """
        
        let email = EmailMessage(bodyHTML: html)
        let result = await bodyExtractor.extractCleanBody(from: email)
        
        XCTAssertTrue(result.contains("Thanks for your message!"))
        XCTAssertTrue(result.contains("I'll get back to you soon"))
        XCTAssertTrue(result.contains("Best regards,"))
        XCTAssertTrue(result.contains("John"))
        XCTAssertFalse(result.contains("On Oct 20, 2025"))
        XCTAssertFalse(result.contains("Jane Doe"))
        XCTAssertFalse(result.contains("I wanted to follow up"))
    }
    
    // MARK: - Signature Tests
    
    func testStripSignature() async {
        let text = """
        Hi there,

        This is the main content of the email.

        Let me know if you have any questions.

        Best regards,
        John Smith
        Senior Developer
        Acme Corporation

        --
        Sent from my iPhone
        Please consider the environment before printing this email.

        Confidentiality Notice: This email and any attachments are confidential.
        """
        
        let email = EmailMessage(bodyPlainText: text)
        let result = await bodyExtractor.extractCleanBody(from: email)
        
        XCTAssertTrue(result.contains("Hi there,"))
        XCTAssertTrue(result.contains("This is the main content of the email"))
        XCTAssertTrue(result.contains("Let me know if you have any questions"))
        XCTAssertTrue(result.contains("Best regards,"))
        XCTAssertTrue(result.contains("John Smith"))
        XCTAssertTrue(result.contains("Senior Developer"))
        XCTAssertTrue(result.contains("Acme Corporation"))
        XCTAssertFalse(result.contains("Sent from my iPhone"))
        XCTAssertFalse(result.contains("Please consider the environment"))
        XCTAssertFalse(result.contains("Confidentiality Notice"))
    }
    
    // MARK: - Golden Record Tests
    
    func testHTMLWithImagesGoldenRecord() async throws {
        let email = try await loadFixture("html-with-images")
        let cleanBody = await bodyExtractor.extractCleanBody(from: email)
        let expectedBody = try loadGoldenRecord("html-with-images")
        
        XCTAssertEqual(cleanBody.trimmingCharacters(in: .whitespacesAndNewlines),
                      expectedBody.trimmingCharacters(in: .whitespacesAndNewlines),
                      "Cleaned body doesn't match golden record for fixture: html-with-images")
    }
    
    func testQuotedReplyGoldenRecord() async throws {
        try await assertCleanBodyMatches(fixture: "quoted-reply")
    }
    
    func testSignaturePatternsGoldenRecord() async throws {
        try await assertCleanBodyMatches(fixture: "signature-patterns")
    }
    
    // MARK: - Edge Cases
    
    func testEmptyBody() async {
        let email = EmailMessage()
        let result = await bodyExtractor.extractCleanBody(from: email)
        XCTAssertEqual(result, "")
    }
    
    func testMalformedHTML() async {
        let malformedHTML = "<html><body><p>Unclosed tag</body>"
        let email = EmailMessage(bodyHTML: malformedHTML)
        let result = await bodyExtractor.extractCleanBody(from: email)
        
        // Should still extract text even with malformed HTML
        XCTAssertTrue(result.contains("Unclosed tag"))
        XCTAssertFalse(result.contains("<"))
        XCTAssertFalse(result.contains(">"))
    }
    
    func testMixedContent() async {
        let mixedContent = """
        Plain text content here.
        
        <p>HTML content here.</p>
        
        More plain text.
        
        > Quoted content here.
        
        Final content.
        """
        
        let email = EmailMessage(bodyPlainText: mixedContent)
        let result = await bodyExtractor.extractCleanBody(from: email)
        
        XCTAssertTrue(result.contains("Plain text content here"))
        XCTAssertTrue(result.contains("HTML content here"))
        XCTAssertTrue(result.contains("More plain text"))
        XCTAssertTrue(result.contains("Final content"))
        XCTAssertFalse(result.contains("Quoted content here"))
    }
}

// MARK: - Test Errors

enum TestError: Error {
    case fixtureNotFound(String)
    case goldenRecordNotFound(String)
    
    var localizedDescription: String {
        switch self {
        case .fixtureNotFound(let name):
            return "Test fixture not found: \(name)"
        case .goldenRecordNotFound(let name):
            return "Golden record not found: \(name)"
        }
    }
}
