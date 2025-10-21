import Foundation
import XCTest
@testable import HavenCore

final class MailFiltersTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2025-01-10T12:00:00Z")!
    
    func testDSLParsingAndEvaluation() throws {
        var config = MailFiltersConfig()
        config.inline = [try MailFilterExpression.fromDSL("folder_exact('Inbox/Receipts') and date in last 30d and (regex(subject, '(?i)receipt') or contains(body, 'order #'))")]
        config.combinationMode = .all
        
        let evaluator = try MailFilterEvaluator.build(
            config: config,
            options: .init(nowProvider: { self.now })
        )
        
        // Prefilter should require Inbox/Receipts
        XCTAssertTrue(evaluator.prefilter.shouldRestrictToFolderList)
        XCTAssertTrue(evaluator.prefilter.isIncluded(folder: "Inbox/Receipts"))
        XCTAssertFalse(evaluator.prefilter.isIncluded(folder: "Inbox/Bills"))
        
        var message = EmailFilterMessageContext(
            subject: "Your receipt from Example Store",
            bodyPlaintext: "Order #12345 processed successfully",
            from: ["merchant@example.com"],
            folderPath: "Inbox/Receipts",
            date: now.addingTimeInterval(-7 * 86_400),
            attachments: []
        )
        
        XCTAssertTrue(evaluator.evaluate(message))
        
        message.folderPath = "Inbox/Bills"
        XCTAssertFalse(evaluator.evaluate(message))
    }
    
    func testEnvironmentJSONFilter() throws {
        let jsonFilter = """
        {
          "op": "and",
          "args": [
            {"pred": "folder_exact", "args": ["Inbox/Receipts"]},
            {"pred": "regex", "args": ["subject", "(?i)invoice"]},
            {"pred": "date_range", "args": ["-90d"]}
          ]
        }
        """
        
        var config = MailFiltersConfig(
            inline: [],
            files: [],
            environmentVariable: "EMAIL_COLLECTOR_FILTERS",
            prefilter: MailPrefilterConfig()
        )
        config.combinationMode = .all
        
        let evaluator = try MailFilterEvaluator.build(
            config: config,
            options: .init(
                environment: ["EMAIL_COLLECTOR_FILTERS": jsonFilter],
                nowProvider: { self.now }
            )
        )
        
        var message = EmailFilterMessageContext(
            subject: "Invoice 22-019",
            folderPath: "Inbox/Receipts",
            date: now.addingTimeInterval(-5 * 86_400)
        )
        
        XCTAssertTrue(evaluator.evaluate(message))
        
        message.subject = "Payment reminder"
        XCTAssertFalse(evaluator.evaluate(message))
    }
    
    func testYAMLFileLoadingAndPrefilterMerge() throws {
        let yaml = """
        combination_mode: any
        default_action: include
        prefilter:
          include_folders:
            - Inbox/Finance
          exclude_folders:
            - Inbox/Finance/Spam
        filters:
          - folder_prefix("Inbox/Finance/Taxes") and contains(subject, "tax")
          - folder_prefix("Inbox/Finance/Invoices") and regex(subject, "(?i)invoice")
        """
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("yaml")
        try yaml.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        var config = MailFiltersConfig(
            inline: [],
            files: [tempURL.path],
            environmentVariable: nil,
            prefilter: MailPrefilterConfig()
        )
        
        let evaluator = try MailFilterEvaluator.build(
            config: config,
            options: .init(nowProvider: { self.now })
        )
        
        XCTAssertEqual(evaluator.combinationMode, .any)
        XCTAssertTrue(evaluator.prefilter.isIncluded(folder: "Inbox/Finance/Taxes"))
        XCTAssertTrue(evaluator.prefilter.isIncluded(folder: "Inbox/Finance/Invoices"))
        XCTAssertTrue(evaluator.prefilter.isExcluded(folder: "Inbox/Finance/Spam"))
        
        var message = EmailFilterMessageContext(
            subject: "Quarterly tax reminder",
            folderPath: "Inbox/Finance/Taxes",
            date: now
        )
        XCTAssertTrue(evaluator.evaluate(message))
        
        message.folderPath = "Inbox/Finance/Spam"
        XCTAssertFalse(evaluator.evaluate(message))
    }
    
    func testRelativeDateWindow() throws {
        var config = MailFiltersConfig()
        config.inline = [try MailFilterExpression.fromDSL("date in last 3d")]
        
        let evaluator = try MailFilterEvaluator.build(
            config: config,
            options: .init(nowProvider: { self.now })
        )
        
        var message = EmailFilterMessageContext(
            subject: "Recent email",
            date: now.addingTimeInterval(-2 * 86_400)
        )
        XCTAssertTrue(evaluator.evaluate(message))
        
        message.date = now.addingTimeInterval(-5 * 86_400)
        XCTAssertFalse(evaluator.evaluate(message))
    }
    
    func testAttachmentMimePredicate() throws {
        var config = MailFiltersConfig()
        config.inline = [try MailFilterExpression.fromDSL("has_attachment() and attachment_mime('/pdf$/')")]
        
        let evaluator = try MailFilterEvaluator.build(
            config: config,
            options: .init(nowProvider: { self.now })
        )
        
        var message = EmailFilterMessageContext(
            subject: "Monthly statement",
            attachments: [EmailAttachmentInfo(filename: "statement.pdf", mimeType: "application/pdf")]
        )
        XCTAssertTrue(evaluator.evaluate(message))
        
        message.attachments = [EmailAttachmentInfo(filename: "photo.jpg", mimeType: "image/jpeg")]
        XCTAssertFalse(evaluator.evaluate(message))
    }
}
