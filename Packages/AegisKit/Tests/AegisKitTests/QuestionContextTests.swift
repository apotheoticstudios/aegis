@testable import AegisKit
import Foundation
import XCTest

/// Questions get their conversation (#153): up to three earlier messages in the thread, including ones
/// from before the window, which are context only. Synthetic events only.
final class QuestionContextTests: XCTestCase {
    private let window = (start: Date(timeIntervalSince1970: 1_791_300_000), end: Date(timeIntervalSince1970: 1_791_386_400))

    private func message(_ record: String, _ body: String, minutes: Double, thread: String = "iMessage;-;+61400000111") throws -> Event {
        try changed(exampleEvents()[0], record) {
            $0.source = .imessage; $0.body = body; $0.threadID = thread; $0.title = nil
            $0.eventTime = self.window.start.addingTimeInterval(minutes * 60)
        }
    }

    func testQuestionGetsThreeEarlierMessagesIncludingFromBeforeTheWindow() throws {
        let events = try [
            message("old-1", "Sent you the folder link", minutes: -600),
            message("old-2", "It has the photos", minutes: -300),
            message("other", "Unrelated chat", minutes: -200, thread: "iMessage;-;+61400000222"),
            message("in-1", "Did it arrive", minutes: 10),
            message("question", "How do I access this?", minutes: 20),
        ]
        let policy = try BriefInputPolicy(
            windowStart: window.start, windowEnd: window.end, contextStart: window.start.addingTimeInterval(-3 * 86400)
        )
        let input = try policy.build(events)
        let records = Set(events.filter { input.eventIDs.contains($0.id) }.map(\.sourceRecordID))
        XCTAssertEqual(records, ["question", "in-1", "old-2", "old-1"])
        XCTAssertEqual(input.omittedEvents, 0, "context from before the window is never counted as omitted")
    }

    func testEventsBeforeTheWindowAreNeverItemsOnTheirOwn() throws {
        let events = try [
            message("old", "Anyone free Friday?", minutes: -60),
            message("now", "Morning", minutes: 30),
        ]
        let policy = try BriefInputPolicy(
            windowStart: window.start, windowEnd: window.end, contextStart: window.start.addingTimeInterval(-86400)
        )
        let records = try Set(events.filter { try policy.build(events).eventIDs.contains($0.id) }.map(\.sourceRecordID))
        XCTAssertEqual(records, ["now"])
        XCTAssertThrowsError(try BriefInputPolicy(
            windowStart: window.start,
            windowEnd: window.end,
            contextStart: window.end.addingTimeInterval(1)
        ))
    }

    func testGroupChatsOpenMessagesNotAOneToOneChat() throws {
        let group = try message("group", "Who's in?", minutes: 5, thread: "iMessage;+;chat000000000000000001")
        XCTAssertEqual(EventLink.link(for: group), .app(bundleID: "com.apple.MobileSMS"))
        var direct = try message("direct", "Hi", minutes: 5)
        direct.senderHandle = "+61400000111"
        if case .url = EventLink.link(for: direct) {} else {
            XCTFail("a one-to-one message opens its conversation")
        }
    }
}
