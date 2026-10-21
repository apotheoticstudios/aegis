@testable import AegisKit
import Foundation
import XCTest

final class SenderDisplayTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)

    private func event(_ id: String = "question", thread: String? = "group", offset: Double = 0) -> Event {
        Event(
            source: .imessage, sourceRecordID: id, appID: nil, sender: "source identity", threadID: thread,
            eventTime: start.addingTimeInterval(offset), eventTimeSource: .sent, captureTime: start,
            title: nil, body: "Can you call?", content: .complete, observations: [],
            direction: .incoming, senderHandle: "+61400000001"
        )
    }

    private func policy() throws -> BriefInputPolicy {
        try BriefInputPolicy(windowStart: start, windowEnd: start.addingTimeInterval(100))
    }

    func testContactAndMentionedNameNeverSwapSpeakers() throws {
        var first = event("first")
        first.senderContact = .init(id: "contact-one", name: "Blair Example")
        first.body = "Alex Example said call me. Can you call?"
        first.title = "Alex Example"
        var second = event("second", offset: 1)
        second.senderHandle = "+61400000002"
        second.senderContact = .init(id: "contact-two", name: "Casey Example")
        let input = try policy().build([second, first])
        let lines = input.text.split(separator: "\n")
        XCTAssertTrue(lines[1].contains("from Blair Example"))
        XCTAssertTrue(lines[2].contains("from Casey Example"))
        XCTAssertFalse(lines[1].contains("from Alex Example"))
        XCTAssertEqual(input.text.components(separatedBy: BriefInputPolicy.asksMarker).count - 1, 2)
        first.senderContact = nil
        XCTAssertEqual(SenderDisplay.label(first), "+61400000001")
    }

    func testAmbiguousAndBusinessHandles() throws {
        var message = event()
        for handle in ["12345", "ExampleBank", " +61 400 000 001 "] {
            message.senderHandle = handle
            XCTAssertEqual(SenderDisplay.label(message), handle)
        }
        message.flags = [.ambiguousSender]
        XCTAssertEqual(SenderDisplay.label(message), " +61 400 000 001  (matches several contacts)")
        XCTAssertEqual(SenderDisplay.label(message, ambiguousCount: 2), " +61 400 000 001  (matches 2 contacts)")
        XCTAssertEqual(SenderDisplay.label(message, ambiguousCount: 3), " +61 400 000 001  (matches 3 contacts)")
        XCTAssertTrue(try XCTUnwrap(policy().eventLine(message)).contains("matches several contacts"))
    }

    func testNotificationFallbackAndPhysicalLineSafety() throws {
        var message = event()
        message.source = .notification
        message.senderHandle = nil
        message.sender = "Example App"
        message.appID = "com.example.app"
        XCTAssertEqual(SenderDisplay.label(message), "Example App")
        message.sender = nil
        message.title = "Alex Example"
        message.body = "Alex Example said call me"
        XCTAssertEqual(SenderDisplay.label(message), "com.example.app")
        message.senderContact = .init(id: "contact", name: "Blair\nExample")
        XCTAssertTrue(try XCTUnwrap(policy().eventLine(message)).contains("from Blair Example"))
    }

    func testOutgoingDirectionAndLegacyFallback() throws {
        var message = event()
        message.direction = .outgoing
        XCTAssertTrue(SenderDisplay.isOutgoing(message))
        XCTAssertTrue(try XCTUnwrap(policy().eventLine(message)).contains("from you"))
        message.direction = .incoming
        message.sender = "me"
        XCTAssertFalse(SenderDisplay.isOutgoing(message))
        message.direction = .unknown
        XCTAssertFalse(SenderDisplay.isOutgoing(message))
        message.schemaVersion = "0.1"
        XCTAssertTrue(SenderDisplay.isOutgoing(message))
        XCTAssertEqual(SenderDisplay.label(message), "you")
    }

    func testDecodedV01OwnerRetainsOutgoingEvidence() throws {
        var legacy = event("legacy-reply", offset: 1)
        legacy.sender = "me"
        legacy.body = "Confirmed."
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json["schema_version"] = "0.1"
        for key in ["direction", "sender_handle", "recipients", "sender_contact"] {
            json.removeValue(forKey: key)
        }
        let migrated = try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.schemaVersion, "0.2")
        XCTAssertEqual(migrated.direction, .outgoing)
        XCTAssertEqual(SenderDisplay.label(migrated), "you")
        XCTAssertFalse(try policy().build([migrated, event()]).text.contains(BriefInputPolicy.asksMarker))
    }

    func testOnlyStrictlyLaterOutgoingInSameThreadClosesRequest() throws {
        let question = event()
        var reply = event("reply", offset: 1)
        reply.direction = .outgoing
        reply.body = "Confirmed."
        func remainsOpen(_ outgoing: Event) throws -> Bool {
            let input = try policy().build([outgoing, question])
            return input.text.contains(BriefInputPolicy.asksMarker)
        }
        XCTAssertFalse(try remainsOpen(reply))
        reply.threadID = "elsewhere"
        XCTAssertTrue(try remainsOpen(reply))
        reply.threadID = nil
        XCTAssertTrue(try remainsOpen(reply))
        reply.threadID = ""
        XCTAssertTrue(try remainsOpen(reply))
        reply.threadID = question.threadID
        reply.eventTime = question.eventTime
        XCTAssertTrue(try remainsOpen(reply))
        reply.eventTime = start.addingTimeInterval(-1)
        XCTAssertTrue(try remainsOpen(reply))
        reply.eventTime = start.addingTimeInterval(1)
        reply.direction = .incoming
        reply.sender = "me"
        XCTAssertTrue(try remainsOpen(reply))
        reply.schemaVersion = "0.1"
        XCTAssertFalse(try remainsOpen(reply))
    }
}
