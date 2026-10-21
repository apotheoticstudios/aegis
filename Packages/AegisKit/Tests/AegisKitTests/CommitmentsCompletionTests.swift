@testable import AegisKit
import Foundation
import XCTest

final class CommitmentsCompletionTests: XCTestCase {
    func testEveryVerbCompletionCue() {
        let cases: [(String, [String])] = [
            ("send it", ["sent", "attached", "here it is", "here's the report", "here you go", "forwarded"]),
            ("call", ["called", "rang", "spoke", "tried calling"]),
            ("pay", ["paid", "transferred", "sent the money"]),
            ("book", ["booked", "reserved", "confirmed"]),
            ("fix it", ["done", "fixed", "finished", "sorted", "all good"]),
            ("finish it", ["done"]), ("bring it", ["done"]),
        ]
        for (action, cues) in cases {
            let promise = CommitmentFixture.event("promise", "I'll " + action + " tomorrow")
            for cue in cues {
                let reply = CommitmentFixture.reply(promise, cue)
                XCTAssertTrue(CommitmentFixture.compute([promise, reply]).isEmpty, action + ": " + cue)
            }
        }
        for text in ["On it", "Leave it with me"] {
            let promise = CommitmentFixture.event("short", text)
            XCTAssertTrue(CommitmentFixture.compute([promise, CommitmentFixture.reply(promise, "done")]).isEmpty)
        }
    }

    func testAttachmentOnlyCompletesSendingAndIncomingAcknowledgementsCompleteAnyVerb() {
        let promise = CommitmentFixture.event("promise", "I'll send it tomorrow")
        var attachment = CommitmentFixture.reply(promise, "")
        attachment.flags = [.attachmentOnly]
        XCTAssertTrue(CommitmentFixture.compute([promise, attachment]).isEmpty)
        let call = CommitmentFixture.event("call", "I'll call tomorrow")
        attachment.threadID = call.threadID
        XCTAssertEqual(CommitmentFixture.compute([call, attachment]).count, 1)
        for cue in ["got it", "received", "thanks for sending", "that works", "all good"] {
            XCTAssertTrue(CommitmentFixture.compute([call, CommitmentFixture.reply(call, cue, incoming: true)]).isEmpty, cue)
        }
    }

    func testCheckAndGetBackNeedTenMinutesAndNoCompletionWords() {
        for text in [
            "I'll check",
            "I'll look into it",
            "I'll review it",
            "I'll get back to you",
            "I'll let you know",
            "Let me check",
            "Let me find out",
            "Let me ask",
        ] {
            let promise = CommitmentFixture.event("promise", text)
            let early = CommitmentFixture.reply(promise, "Example update", after: 599)
            let late = CommitmentFixture.reply(promise, "Example update", after: 600)
            let now = promise.eventTime.addingTimeInterval(601)
            XCTAssertEqual(CommitmentFixture.compute([early, promise], now: now).count, 1, text)
            XCTAssertTrue(CommitmentFixture.compute([late, promise], now: now).isEmpty, text)
        }
    }

    func testCompletionsMustBeLaterInTheSameMessagesThread() {
        let promise = CommitmentFixture.event("promise", "I'll send it tomorrow")
        for seconds in [-1.0, 0.0, 61.0] {
            let reply = CommitmentFixture.reply(promise, "sent", after: seconds)
            XCTAssertEqual(CommitmentFixture.compute([reply, promise]).count, 1)
        }
        var other = CommitmentFixture.reply(promise, "got it", incoming: true)
        other.threadID = "another thread"
        XCTAssertEqual(CommitmentFixture.compute([promise, other]).count, 1)
        var threadless = promise
        threadless.threadID = nil
        var reply = CommitmentFixture.reply(threadless, "sent")
        XCTAssertEqual(CommitmentFixture.compute([threadless, reply]).count, 1)
        reply.direction = .unknown
        reply.threadID = promise.threadID
        XCTAssertEqual(CommitmentFixture.compute([promise, reply]).count, 1)
    }

    func testEmailUsesFirstRecipientOrIncomingSenderRatherThanThreadID() {
        var promise = CommitmentFixture.event("mail", "I'll send it tomorrow", source: .email)
        promise.recipients = ["alex@example.com", "other@example.com"]
        var reply = CommitmentFixture.reply(promise, "sent")
        reply.threadID = "different email thread"
        reply.recipients = ["ALEX@example.com"]
        XCTAssertTrue(CommitmentFixture.compute([promise, reply]).isEmpty)
        reply.recipients = ["other@example.com", "alex@example.com"]
        XCTAssertEqual(CommitmentFixture.compute([promise, reply]).count, 1)
        reply = CommitmentFixture.reply(promise, "got it", incoming: true)
        reply.threadID = nil
        XCTAssertTrue(CommitmentFixture.compute([promise, reply]).isEmpty)
        reply.senderHandle = "other@example.com"
        XCTAssertEqual(CommitmentFixture.compute([promise, reply]).count, 1)
        reply.source = .imessage
        reply.threadID = promise.threadID
        XCTAssertEqual(CommitmentFixture.compute([promise, reply]).count, 1)
    }

    func testQuotedHistoryNegatedCompletionAndFuturePromisesDoNotComplete() {
        let promise = CommitmentFixture.event("promise", "I'll send it tomorrow", source: .email)
        for text in [
            "\"sent\"",
            "“sent”",
            "Not sent yet",
            "I haven't sent it",
            "I'll have it sent tomorrow",
            "Was it sent?",
            "Example update\n> sent",
            "Example update\nOn Tuesday Example Alex wrote:\nsent",
        ] {
            let reply = CommitmentFixture.reply(promise, text)
            XCTAssertTrue(CommitmentFixture.compute([promise, reply]).contains { $0.eventID == promise.id }, text)
        }
        for text in ["I haven't received it", "Not all good", "Got it?", "\"got it\""] {
            let reply = CommitmentFixture.reply(promise, text, incoming: true)
            XCTAssertEqual(CommitmentFixture.compute([promise, reply]).count, 1, text)
        }
    }

    func testStaleUndatedExpiredDatedAndSevenDayWindow() {
        let undated = CommitmentFixture.event("undated", "I'll bring it")
        let madeAt = undated.eventTime
        XCTAssertEqual(CommitmentFixture.compute([undated], now: madeAt.addingTimeInterval(3 * 86400)).count, 1)
        XCTAssertTrue(CommitmentFixture.compute([undated], now: madeAt.addingTimeInterval(3 * 86400 + 1)).isEmpty)
        let dated = CommitmentFixture.event("dated", "I'll send it today")
        let due = CommitmentFixture.date(hour: 23, minute: 59, second: 59)
        XCTAssertEqual(CommitmentFixture.compute([dated], now: due.addingTimeInterval(3 * 86400)).count, 1)
        XCTAssertTrue(CommitmentFixture.compute([dated], now: due.addingTimeInterval(3 * 86400 + 1)).isEmpty)
        let farDue = CommitmentFixture.event("future-due", "I'll send it in 10 days")
        XCTAssertEqual(CommitmentFixture.compute([farDue], now: madeAt.addingTimeInterval(7 * 86400)).count, 1)
        XCTAssertTrue(CommitmentFixture.compute([farDue], now: madeAt.addingTimeInterval(7 * 86400 + 1)).isEmpty)
        XCTAssertTrue(CommitmentFixture.compute([farDue], now: madeAt.addingTimeInterval(-1)).isEmpty)
    }
}
