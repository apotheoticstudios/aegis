@testable import AegisKit
import Foundation
import XCTest

/// ADR-0038 stage 2: what Claude's read tools may return under the owner's switches, the run's limits, and the MCP
/// messages (synthetic data only).
final class ClaudeToolsTests: XCTestCase {
    private let all = Set(ClaudeTools.Category.allCases)
    private let text = CommitmentFixture.event("t1", "Running late, see you at 6?", source: .imessage)
    private let mail = CommitmentFixture.event("m1", "Invoice attached", source: .email)
    private let alert = CommitmentFixture.event("n1", "Package delivered", source: .notification)

    func testSourcesMapToTheOwnersSwitches() {
        XCTAssertEqual(ClaudeTools.Category(.imessage), .messages)
        XCTAssertEqual(ClaudeTools.Category(.sms), .messages)
        XCTAssertEqual(ClaudeTools.Category(.email), .mail)
        XCTAssertEqual(ClaudeTools.Category(.notification), .notifications)
    }

    func testItemsOfASwitchedOffSourceNeverGo() throws {
        let payload = ClaudeTools.items([text, mail, alert], enabled: all.subtracting([.mail]))
        XCTAssertFalse(payload.isError)
        XCTAssertTrue(payload.text.contains("Running late"))
        XCTAssertFalse(payload.text.contains("Invoice"))
        XCTAssertEqual(payload.counts, [.messages: 1, .notifications: 1])
        XCTAssertTrue(payload.text.hasPrefix(#"{"note":"\#(ClaudeTools.dataNote)""#))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.text.utf8)) as? [String: Any])
        XCTAssertEqual((object["items"] as? [Any])?.count, 2)
        XCTAssertFalse(payload.text.contains("+61"), "no handles or recipients")
        XCTAssertTrue(ClaudeTools.items([text], enabled: [.calendar, .memory]).isError)
    }

    /// A brief, waiting list, promise or done item goes only when every item it cites is from a source left on and
    /// known to AegisCore.
    func testDerivedResultsFollowTheirCitedSources() {
        let sources: [String: ClaudeTools.Category] = [text.id: .messages, mail.id: .mail]
        let enabled = all.subtracting([.mail])
        let brief = Brief(
            generatedAt: Date(), windowStart: Date(), windowEnd: Date(), model: nil, items: [
                .init(text: "Reply to Sam about dinner", priority: .urgent, eventIDs: [text.id]),
                .init(text: "Pay the invoice", priority: .urgent, eventIDs: [mail.id]),
                .init(text: "Mixed", priority: .urgent, eventIDs: [text.id, mail.id]),
                .init(text: "Unknown source", priority: .urgent, eventIDs: ["ev_missing"]),
            ], omittedEvents: 0
        )
        let stored = StoredBrief(brief: brief, inputRevision: "r", coverage: [], storedAt: Date())
        let payload = ClaudeTools.brief(stored, sources: sources, enabled: enabled)
        XCTAssertTrue(payload.text.contains("Reply to Sam"))
        for left in ["Pay the invoice", "Mixed", "Unknown source"] {
            XCTAssertFalse(payload.text.contains(left), left)
        }
        let person = Brief.Person(id: "contact:1", name: "Sam")
        let people = ClaudeTools.people([
            PersonWaiting(person: person, waitingSince: Date(), questions: 1, latest: "Dinner?", eventIDs: [text.id]),
            PersonWaiting(person: person, waitingSince: Date(), questions: 1, latest: "Invoice?", eventIDs: [mail.id]),
        ], sources: sources, enabled: enabled)
        XCTAssertTrue(people.text.contains("Dinner?"))
        XCTAssertFalse(people.text.contains("Invoice?"))
        let promises = ClaudeTools.promises([
            Commitment(personID: nil, person: "Sam", text: "I'll call tomorrow", due: nil, madeAt: Date(), eventID: text.id),
            Commitment(personID: nil, person: "Ari", text: "I'll send it Friday", due: nil, madeAt: Date(), eventID: mail.id),
        ], sources: sources, enabled: enabled)
        XCTAssertEqual(promises.counts, [.messages: 1])
        let done = ClaudeTools.done([
            DoneItem(kind: .answered, text: "Answered Sam", time: Date(), personID: nil, eventIDs: [text.id], scheduleIDs: []),
            DoneItem(kind: .reminderCompleted, text: "Bins out", time: Date(), personID: nil, eventIDs: [], scheduleIDs: ["r1"]),
        ], sources: sources, enabled: enabled.subtracting([.calendar]))
        XCTAssertTrue(done.text.contains("Answered Sam"))
        XCTAssertFalse(done.text.contains("Bins out"), "a reminder needs the calendar switch")
    }

    func testCalendarMemoryAndHealthHaveTheirOwnSwitches() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(ClaudeTools.schedule([], [], enabled: all.subtracting([.calendar])).isError)
        XCTAssertFalse(ClaudeTools.schedule([], [], enabled: [.calendar]).isError)
        let note = MemoryNote(id: "n", kind: .preference, text: "Prefers mornings", createdAt: start)
        XCTAssertTrue(ClaudeTools.memories([note], enabled: all.subtracting([.memory])).isError)
        XCTAssertTrue(ClaudeTools.memories([note], enabled: [.memory]).text.contains("Prefers mornings"))
        let status = CoreStatus(
            sources: [SourceCoverage(source: .messages, status: .ok, events: 12, lastSuccess: start)],
            lastBriefAt: nil, nextBriefAt: nil, generating: false
        )
        XCTAssertTrue(ClaudeTools.health(status, enabled: [.health]).text.contains(#""events":12"#))
        XCTAssertTrue(ClaudeTools.health(status, enabled: [.messages]).isError)
    }

    func testLongResultsAreCutToFitAndSayHowManyWereLeftOut() throws {
        let long = String(repeating: "x", count: 5000)
        let events = (0 ..< 200).map { CommitmentFixture.event("e\($0)", long) }
        let payload = ClaudeTools.items(events, enabled: all)
        XCTAssertLessThanOrEqual(payload.text.utf8.count, ClaudeTools.Server.maxResultBytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.text.utf8)) as? [String: Any])
        let sent = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(sent.count + (object["left_out"] as? Int ?? 0), 200)
        XCTAssertEqual((sent.first?["text"] as? String)?.count, ClaudeTools.maxText)
    }

    // MARK: The MCP server

    func testOnlyToolsWithASwitchOnAreOffered() throws {
        var server = ClaudeTools.Server(enabled: [.calendar, .memory])
        XCTAssertEqual(server.tools, [.schedule, .doneToday, .memoryNotes])
        let list = try reply(server.handle(rpc(1, "tools/list")))
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["schedule", "done_today", "memory_notes"])
        XCTAssertEqual(ClaudeTools.Server(enabled: []).tools, [])
        XCTAssertEqual(ClaudeTools.Tool.brief.fullName, "mcp__aegis__brief")
    }

    func testCallsAreCheckedAndClamped() throws {
        var server = ClaudeTools.Server(enabled: all)
        XCTAssertEqual(
            server.handle(rpc(1, "tools/call", ["name": "recent_items", "arguments": ["limit": 500]])),
            .call(id: .number(1), .recentItems(limit: 50))
        )
        XCTAssertEqual(
            server.handle(rpc("a", "tools/call", ["name": "schedule", "arguments": ["days_ahead": -3]])),
            .call(id: .string("a"), .schedule(daysBack: 0, daysAhead: 0))
        )
        let ids = (0 ..< 30).map { "ev_\($0)" }
        XCTAssertEqual(
            server.handle(rpc(2, "tools/call", ["name": "read_items", "arguments": ["ids": ids]])),
            .call(id: .number(2), .readItems(ids: Array(ids.prefix(CoreRequest.maxSourceIDs))))
        )
        let invalid = try reply(server.handle(rpc(3, "tools/call", ["name": "read_items", "arguments": ["ids": "ev_1"]])))
        XCTAssertEqual((invalid["result"] as? [String: Any])?["isError"] as? Bool, true)
        let unknown = try reply(server.handle(rpc(4, "tools/call", ["name": "send_message", "arguments": [:]])))
        XCTAssertNotNil(unknown["error"])
        var calendarOnly = ClaudeTools.Server(enabled: [.calendar])
        XCTAssertNotNil(try reply(calendarOnly.handle(rpc(5, "tools/call", ["name": "recent_items"])))["error"], "not offered")
    }

    func testARunHasLimitsOnCallsAndBytes() throws {
        var server = ClaudeTools.Server(enabled: all)
        for index in 0 ..< ClaudeTools.Server.maxCalls {
            guard case .call = server.handle(rpc(index, "tools/call", ["name": "brief"])) else { return XCTFail("call \(index)") }
        }
        let over = try reply(server.handle(rpc(99, "tools/call", ["name": "brief"])))
        XCTAssertEqual((over["result"] as? [String: Any])?["isError"] as? Bool, true)

        var bytes = ClaudeTools.Server(enabled: all)
        let big = ClaudeTools.Payload(
            text: String(repeating: "x", count: ClaudeTools.Server.maxResultBytes),
            counts: [.messages: 5],
            isError: false
        )
        for index in 0 ..< 4 {
            _ = bytes.result(id: .number(index), big)
        }
        XCTAssertEqual(bytes.counts, [.messages: 20])
        let refused = try reply(.reply(bytes.result(id: .number(9), big)))
        XCTAssertEqual((refused["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual(bytes.counts, [.messages: 20], "a withheld result isn't counted as sent")
    }

    func testHandshakeMessagesAndNotifications() throws {
        var server = ClaudeTools.Server(enabled: all)
        let start = try reply(server.handle(rpc(0, "initialize", ["protocolVersion": "2025-11-25"])))
        let result = try XCTUnwrap(start["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "aegis")
        let note = try reply(server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
        XCTAssertNil(note["id"])
        XCTAssertNotNil(try reply(server.handle(rpc(7, "resources/list")))["error"])
    }

    // MARK: Helpers

    private func rpc(_ id: Any, _ method: String, _ params: [String: Any] = [:]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])) ?? Data()
    }

    private func reply(_ step: ClaudeTools.Server.Step) throws -> [String: Any] {
        guard case let .reply(data) = step else { throw NotAReply() }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct NotAReply: Error {}
