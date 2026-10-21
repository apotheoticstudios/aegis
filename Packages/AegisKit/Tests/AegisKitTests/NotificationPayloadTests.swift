import AegisKit
import Foundation
import XCTest

final class NotificationPayloadTests: XCTestCase {
    private func plist(_ value: Any, format: PropertyListSerialization.PropertyListFormat = .binary) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
    }

    func testBinaryPlistContentAndUnicodeArePreserved() throws {
        let title = "Jose\u{301}"
        let subtitle = "safe\u{202E}txet desrever"
        let body = "👨‍👩‍👧‍👦 🇬🇧 👍🏽\u{0000}\u{200B}hidden characters"
        let data = try plist(["app": "com.example.chat", "req": ["titl": title, "subt": subtitle, "body": body]])
        XCTAssertTrue(data.starts(with: Data("bplist00".utf8)))
        let payload = try NotificationPayload.decode(data)
        XCTAssertEqual(payload.title, title)
        XCTAssertEqual(payload.subtitle, subtitle)
        XCTAssertEqual(payload.body, body)
        XCTAssertEqual(payload, try NotificationPayload.decode(data))
    }

    func testNonStringTitleAndSubtitleBecomeNil() throws {
        for value: Any in [["Breaking", "news"], 42, true, Data([1]), ["key": "value"]] {
            let payload = try NotificationPayload.decode(plist(["req": ["titl": value, "subt": value, "body": "Synthetic body"]]))
            XCTAssertNil(payload.title)
            XCTAssertNil(payload.subtitle)
            XCTAssertEqual(payload.body, "Synthetic body")
        }
    }

    func testMissingNonStringAndEmptyBodyBecomeEmpty() throws {
        let requests: [[String: Any]] = [[:], ["body": ""], ["body": 42], ["body": true], ["body": ["text"]]]
        for request in requests {
            let payload = try NotificationPayload.decode(plist(["req": request]))
            XCTAssertNil(payload.title)
            XCTAssertNil(payload.subtitle)
            XCTAssertEqual(payload.body, "")
        }
        let payload = try NotificationPayload.decode(plist(["req": ["titl": "Hidden preview", "body": ""]]))
        XCTAssertEqual(payload.title, "Hidden preview")
        XCTAssertEqual(payload.body, "")
    }

    func testMissingOrNonDictionaryRequestIsEmpty() throws {
        let values: [[String: Any]] = [[:], ["req": "text"], ["req": ["array"]], ["req": 42]]
        for value in values {
            let payload = try NotificationPayload.decode(plist(value))
            XCTAssertNil(payload.title)
            XCTAssertNil(payload.subtitle)
            XCTAssertEqual(payload.body, "")
        }
    }

    func testNonDictionaryPlistsHaveTypedErrors() throws {
        for value: Any in [["array"], "text", 42, true, Data([1])] {
            let data = try plist(value)
            XCTAssertThrowsError(try NotificationPayload.decode(data)) { error in
                XCTAssertEqual(error as? NotificationPayloadError, .notDictionary)
            }
        }
    }

    func testCorruptTruncatedAndNonPlistPayloadsHaveTypedErrors() throws {
        let valid = try plist(["req": ["body": "Synthetic body"]])
        for data in [Data(), Data("not a plist".utf8), Data("bplist00\u{0000}\u{0001}garbage".utf8), Data(valid.prefix(12))] {
            XCTAssertThrowsError(try NotificationPayload.decode(data)) { error in
                XCTAssertEqual(error as? NotificationPayloadError, .invalidPropertyList)
            }
        }
    }

    func testXMLPlistsAreAcceptedLikeThePythonReader() throws {
        let data = try plist(["req": ["body": "Synthetic body"]], format: .xml)
        XCTAssertEqual(try NotificationPayload.decode(data).body, "Synthetic body")
    }
}
