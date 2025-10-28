import XCTest
@testable import Email
@testable import HavenCore

final class EmailServiceMIMETests: XCTestCase {
    
    func testParseEmlxWithQuotedPrintable() async throws {
        let emailService = EmailService()
        
        // Create a test .emlx file with quoted-printable content
        let testContent = """
Subject: Test Email with Quoted-Printable Content
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: quoted-printable

Hi Chris,=20
=20
This is a reminder that you have an=3D appointment with Lisa A. Paquette, LMHC - Gentle River Counseling at 12:00=3D pm (EDT) on Thursday, October 3rd.+
=20
Your unique video appointment link:=3D Join your Video Appointment (3D"https://video.simplepractice.com/appt-adf0ab4c20a4271dab1671642=3D)+
=20
Imp=3D ortant: Before joining the appointment from the mobile or tablet app, m=3D ake sure to update to the latest Telehealth app version.+
=20
Add to your Calendar and your link =3D to join the Telehealth appointment will be included:+
iCloud (3D"https://lisa-paquette.clientsecure.me/client=3D)Google (3D"http://www.g=3D)Outlook (3D"https:/=3D)+
=20
Lisa A. Paquette, LMHC - Gentle Riv=3D er Counseling+
=20
Please contact me with any question=3D s or changes.+
=20
[PHONE_REDACTED]+
=20
Don't have our Telehealth app?+
iOS App Store (3D"https://itunes.apple.com/us/app/simplepractice-video=3D)+
Google Play Store (3D"https://play.google.com/store/apps/details?id=3Dcom.=3D)+
=20
Get tips (3D"https://account.simplepractice.com/accounts/zendesk_sign_i=3D) on how to have a good video=3D appointment.+
=20
Email by SimplePractice.com on behalf of Lisa A. Paquette, LMHC - Gentl=3D e River Counseling+
Unsubscribe from appointment reminders. (3D"https://secure.simplepractice.com/unsub/u/ec174794-c445-48=3D)+
=20
Powered By3D"Simplepractice+
=20
Privacy (3D"https://www.simplepractice.com/c/privacy") =3D B7 Terms (3D"https://www.simplepractice.com/c/t=3D)+
=20
=20
"""
        
        // Create temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test-quoted-printable.emlx")
        
        // Write the content with byte count prefix (emlx format)
        let contentData = testContent.data(using: .utf8)!
        let byteCount = contentData.count
        let emlxContent = "\(byteCount)\n\(testContent)"
        
        try emlxContent.write(to: tempFile, atomically: true, encoding: .utf8)
        
        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }
        
        // Parse the email
        let email = try await emailService.parseEmlxFile(at: tempFile)
        
        // Verify the content was properly decoded
        XCTAssertNotNil(email.bodyPlainText)
        let bodyText = email.bodyPlainText!
        
        // Check that quoted-printable characters were decoded
        XCTAssertFalse(bodyText.contains("=20"), "Should not contain =20")
        XCTAssertFalse(bodyText.contains("=3D"), "Should not contain =3D")
        XCTAssertTrue(bodyText.contains("Hi Chris,"), "Should contain decoded text")
        XCTAssertTrue(bodyText.contains("appointment"), "Should contain decoded text")
        XCTAssertTrue(bodyText.contains("Lisa A. Paquette"), "Should contain decoded text")
        
        // Verify headers
        XCTAssertEqual(email.subject, "Test Email with Quoted-Printable Content")
        XCTAssertEqual(email.headers["content-type"], "text/plain; charset=utf-8")
        XCTAssertEqual(email.headers["content-transfer-encoding"], "quoted-printable")
    }
    
    func testParseRFC822WithQuotedPrintable() async throws {
        let emailService = EmailService()
        
        let content = """
Subject: Test Email
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: quoted-printable

Hello=20World=3D
This is a test=20message.
"""
        
        let email = try await emailService.parseRFC822String(content)
        
        XCTAssertEqual(email.subject, "Test Email")
        XCTAssertNotNil(email.bodyPlainText)
        
        let bodyText = email.bodyPlainText!
        XCTAssertFalse(bodyText.contains("=20"), "Should not contain =20")
        XCTAssertFalse(bodyText.contains("=3D"), "Should not contain =3D")
        XCTAssertTrue(bodyText.contains("Hello World="), "Should contain decoded text")
        XCTAssertTrue(bodyText.contains("This is a test message."), "Should contain decoded text")
    }
    
    func testParseMultipartMessage() async throws {
        let emailService = EmailService()
        
        let content = """
Subject: Multipart Test
Content-Type: multipart/alternative; boundary="boundary123"

--boundary123
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: quoted-printable

Hello=20World

--boundary123
Content-Type: text/html; charset=utf-8
Content-Transfer-Encoding: quoted-printable

<html><body>Hello=20World</body></html>

--boundary123--
"""
        
        let email = try await emailService.parseRFC822String(content)
        
        XCTAssertEqual(email.subject, "Multipart Test")
        
        // Should prefer plain text over HTML
        XCTAssertNotNil(email.bodyPlainText)
        XCTAssertNotNil(email.bodyHTML)
        
        let plainText = email.bodyPlainText!
        let htmlText = email.bodyHTML!
        
        XCTAssertFalse(plainText.contains("=20"), "Plain text should not contain =20")
        XCTAssertFalse(htmlText.contains("=20"), "HTML should not contain =20")
        XCTAssertTrue(plainText.contains("Hello World"), "Plain text should contain decoded content")
        XCTAssertTrue(htmlText.contains("<html><body>Hello World</body></html>"), "HTML should contain decoded content")
    }
}
