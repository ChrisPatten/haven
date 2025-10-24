@testable import HavenCore
import XCTest

final class ConfigValidationTests: XCTestCase {
    func testMailCollectorsAreMutuallyExclusive() {
        var config = HavenConfig()
        config.modules.mail.enabled = true
        config.modules.mailImap.enabled = true
        
        let loader = ConfigLoader()
        
        XCTAssertThrowsError(try loader.validateConfiguration(config)) { error in
            guard case ConfigError.validationError(let message) = error else {
                XCTFail("Expected validationError, got \(error)")
                return
            }
            
            XCTAssertTrue(
                message.contains("modules.mail") && message.contains("modules.mail_imap"),
                "Error message did not mention both modules: \(message)"
            )
        }
    }
}
