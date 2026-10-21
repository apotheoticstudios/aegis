@testable import AegisKit
import Foundation
import XCTest

/// Links that open an event's original. Synthetic events only.
final class EventLinkTests: XCTestCase {
    private func event(_ source: Event.Source, record: String = "R-1", handle: String? = nil, app: String? = nil) throws -> Event {
        var event = try exampleEvents()[0]
        event.source = source
        event.sourceRecordID = record
        event.senderHandle = handle
        event.appID = app
        event.direction = .incoming
        return event
    }

    func testMailOpensTheEmailByMessageID() throws {
        XCTAssertEqual(
            try EventLink.link(for: event(.email, record: "<abc.123@example.com>")),
            try .url(XCTUnwrap(URL(string: "message://%3Cabc.123@example.com%3E")))
        )
        // Characters outside the safe set are percent-encoded, so the ID can't add URL parts.
        XCTAssertEqual(
            try EventLink.link(for: event(.email, record: "a$b/c?d@example.com")),
            try .url(XCTUnwrap(URL(string: "message://%3Ca%24b%2Fc%3Fd@example.com%3E")))
        )
        XCTAssertNil(try EventLink.link(for: event(.email, record: "  ")))
        XCTAssertNil(try EventLink.link(for: event(.email, record: "ünïcode@example.com")))
    }

    func testMessagesOpensTheConversationWithTheHandle() throws {
        XCTAssertEqual(
            try EventLink.link(for: event(.imessage, handle: "+61 400 000 001")),
            try .url(XCTUnwrap(URL(string: "sms:+61400000001")))
        )
        XCTAssertEqual(
            try EventLink.link(for: event(.imessage, handle: "alex@example.com")),
            try .url(XCTUnwrap(URL(string: "sms:alex@example.com")))
        )
        // A handle that tries to add a body or another address is refused.
        for bad in ["alex@example.com?body=pay", "+61400000001&body=x", "alex@example.com,sam@example.com", "javascript:alert(1)"] {
            XCTAssertNil(try EventLink.link(for: event(.sms, handle: bad)), bad)
        }
        XCTAssertNil(try EventLink.link(for: event(.imessage, handle: nil)))
    }

    func testOutgoingMessagesUseTheRecipient() throws {
        var outgoing = try event(.imessage, handle: nil)
        outgoing.direction = .outgoing
        outgoing.recipients = ["+61400000002"]
        XCTAssertEqual(EventLink.link(for: outgoing), try .url(XCTUnwrap(URL(string: "sms:+61400000002"))))
    }

    func testNotificationsOpenTheirApp() throws {
        XCTAssertEqual(try EventLink.link(for: event(.notification, app: "com.example.bank")), .app(bundleID: "com.example.bank"))
        XCTAssertNil(try EventLink.link(for: event(.notification, app: "../../evil")))
        XCTAssertNil(try EventLink.link(for: event(.notification, app: nil)))
    }

    func testSourcesRequestRoundTripsOverIPC() throws {
        let request = CoreRequest.sources(ids: ["ev_0123456789abcdef"])
        XCTAssertEqual(try IPCCoding.decode(CoreRequest.self, from: IPCCoding.encode(request)), request)
        let response = try CoreResponse.events(exampleEvents())
        XCTAssertEqual(try IPCCoding.decode(CoreResponse.self, from: IPCCoding.encode(response)), response)
    }
}
