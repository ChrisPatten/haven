import XCTest
@testable import IMAP
import HavenCore
import MailCore

final class ImapSessionTests: XCTestCase {
    private let defaultConfig = ImapSessionConfiguration(
        hostname: "imap.example.com",
        port: 993,
        username: "user@example.com",
        security: .tls,
        auth: .appPassword(secretRef: "inline://secret"),
        timeout: 10,
        fetchConcurrency: 2,
        allowsInsecurePlainAuth: false
    )
    
    func testSearchMessagesReturnsSortedUIDs() async throws {
        let secretResolver = InlineSecretResolver(storage: ["inline://secret": Data("password".utf8)])
        var recordedFolders: [String] = []
        let indexSet = MCOIndexSet()
        indexSet.add(42)
        indexSet.add(5)
        let sut = try ImapSession(
            configuration: defaultConfig,
            secretResolver: secretResolver,
            session: MCOIMAPSession(),
            searchExecutor: { _, folder, _ in
                recordedFolders.append(folder)
                return indexSet
            },
            fetchExecutor: { _, _, _ in Data() }
        )
        let uids = try await sut.searchMessages(folder: "INBOX", since: nil, before: nil)
        XCTAssertEqual(uids, [42, 5].sorted(by: >))
        XCTAssertEqual(recordedFolders, ["INBOX"])
    }
    
    func testFetchRFC822ReturnsData() async throws {
        let secretResolver = InlineSecretResolver(storage: ["inline://secret": Data("password".utf8)])
        let expected = Data("Hello".utf8)
        let sut = try ImapSession(
            configuration: defaultConfig,
            secretResolver: secretResolver,
            session: MCOIMAPSession(),
            searchExecutor: { _, _, _ in MCOIndexSet() },
            fetchExecutor: { _, folder, uid in
                XCTAssertEqual(folder, "INBOX")
                XCTAssertEqual(uid, 123)
                return expected
            }
        )
        let data = try await sut.fetchRFC822(folder: "INBOX", uid: 123)
        XCTAssertEqual(data, expected)
    }
    
    func testFetchRetriesOnTransientError() async throws {
        let secretResolver = InlineSecretResolver(storage: ["inline://secret": Data("password".utf8)])
        let transient = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let expected = Data("Retried".utf8)
        var attempts = 0
        let sut = try ImapSession(
            configuration: defaultConfig,
            secretResolver: secretResolver,
            session: MCOIMAPSession(),
            searchExecutor: { _, _, _ in MCOIndexSet() },
            fetchExecutor: { _, _, _ in
                attempts += 1
                if attempts == 1 {
                    throw transient
                }
                return expected
            }
        )
        let data = try await sut.fetchRFC822(folder: "INBOX", uid: 77)
        XCTAssertEqual(data, expected)
        XCTAssertEqual(attempts, 2)
    }
}

private struct InlineSecretResolver: SecretResolving {
    let storage: [String: Data]
    func resolve(secretRef: String) throws -> Data {
        if let value = storage[secretRef] {
            return value
        }
        throw SecretResolverError.itemNotFound(secretRef)
    }
}
