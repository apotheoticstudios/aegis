@testable import AegisKit
import Foundation
import XCTest

/// Regression cases from the issue #57 review, using only invented bytes.
final class EmlxReviewTests: XCTestCase {
    private func parse(_ headers: String, body: Data = Data(), partial: Bool = false, index: Date? = nil) throws -> MailMessage {
        let raw = Data((headers + "\n\n").utf8) + body
        return try Emlx.parse(Data("\(raw.count)\n".utf8) + raw, partial: partial, indexDate: index)
    }

    func testEncryptedFlagForRootAndNestedParts() throws {
        for kind in ["application/pkcs7-mime", "application/x-pkcs7-mime", "multipart/encrypted; boundary=e"] {
            let root = try parse("Content-Type: \(kind)", body: Data("ciphertext".utf8))
            XCTAssertTrue(root.encrypted)
            XCTAssertTrue(root.attachmentOnly)
            let nested = "--b\nContent-Type: text/plain\n\nReadable\n--b\nContent-Type: \(kind)\n\nciphertext\n--b--"
            let mixed = try parse("Content-Type: multipart/mixed; boundary=b", body: Data(nested.utf8), partial: true)
            XCTAssertTrue(mixed.encrypted)
            XCTAssertFalse(mixed.attachmentOnly)
            XCTAssertEqual(mixed.body, "")
            XCTAssertEqual(mixed.content, .unavailable)
            XCTAssertTrue(mixed.truncated)
        }
    }

    func testAttachmentOnlyFlagRequiresAbsenceOfTextParts() throws {
        for headers in ["Content-Type: image/jpeg", "Content-Type: text/plain\nContent-Disposition: attachment"] {
            let mail = try parse(headers, body: Data("attachment".utf8))
            XCTAssertTrue(mail.attachmentOnly)
            XCTAssertFalse(mail.encrypted)
        }
        let attachments = "--b\nContent-Type: image/jpeg\n\nattachment\n--b--"
        XCTAssertTrue(try parse("Content-Type: multipart/mixed; boundary=b", body: Data(attachments.utf8)).attachmentOnly)
        for (kind, body) in [("text/plain", ""), ("text/html", "<script>hidden</script>"), ("text/html", "<p>Visible</p>")] {
            for partial in [false, true] {
                let mail = try parse("Content-Type: \(kind)", body: Data(body.utf8), partial: partial)
                XCTAssertFalse(mail.attachmentOnly)
                XCTAssertFalse(mail.encrypted)
            }
        }
    }

    func testReceivedUsesTopmostHopAndItsLastSemicolonDespiteClockSkew() throws {
        let headers = "Date: invalid\n"
            + "Received: from top.example.com; extra metadata; Tue, 06 Oct 2026 00:00:00 +0000\n"
            + "Received: from lower.example.com; Tue, 06 Oct 2026 23:00:00 +0000"
        let mail = try parse(headers)
        XCTAssertEqual(mail.date, Date(timeIntervalSince1970: 1_791_244_800))
        XCTAssertEqual(mail.dateSource, .received)
        let index = Date(timeIntervalSince1970: 1_791_248_400)
        let invalidTop = "Received: from top.example.com; invalid\nReceived: Tue, 06 Oct 2026 23:00:00 +0000"
        XCTAssertEqual(try parse(invalidTop, index: index).date, index)
        XCTAssertEqual(try parse(invalidTop, index: index).dateSource, .index)
        XCTAssertNil(try parse(invalidTop).date)
    }

    /// A bound on work, not a benchmark: the unbounded salvage path took tens of seconds here, so 5 s
    /// still catches a regression without failing on a busy laptop on battery (1.09 s seen with parallel builds).
    func testOneMegabyteMalformedCharsetBodyParsesQuickly() throws {
        let body = Data(repeating: 0xFF, count: 1024 * 1024)
        let clock = ContinuousClock()
        let start = clock.now
        let mail = try parse("Content-Type: text/plain; charset=gb18030", body: body)
        let elapsed = start.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .seconds(5))
        XCTAssertEqual(mail.body, String(repeating: "\u{FFFD}", count: 64 * 1024 + 1))
        XCTAssertEqual(mail.content, .complete)
        XCTAssertFalse(mail.attachmentOnly)
    }

    func testSalvagePreservesPrefixAndDoesNotLimitValidBodies() throws {
        let prefix = Data(repeating: 65, count: 64 * 1024 - 1)
        let malformed = prefix + Data([0xFF]) + Data("discarded tail".utf8)
        XCTAssertEqual(
            try parse("Content-Type: text/plain; charset=us-ascii", body: malformed).body,
            String(repeating: "A", count: prefix.count) + "\u{FFFD}\u{FFFD}"
        )
        let valid = Data(repeating: 65, count: 128 * 1024)
        XCTAssertEqual(
            try parse("Content-Type: text/plain; charset=us-ascii", body: valid).body,
            String(repeating: "A", count: valid.count)
        )
    }
}
