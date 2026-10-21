@testable import AegisKit
import Foundation
import XCTest

/// The Swift contract must read and write exactly what Stage 0's Python contract does (#58).
final class ContractTests: XCTestCase {
    private static let examples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Prototype/contracts/examples")

    private func exampleLines() throws -> [Data] {
        let text = try String(contentsOf: Self.examples.appendingPathComponent("events.jsonl"), encoding: .utf8)
        return text.split(separator: "\n").filter { !$0.isEmpty }.map { Data($0.utf8) }
    }

    /// Both sides parsed and re-serialized the same way, so formatting differences don't matter.
    private func normalized(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(String(bytes: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8))
    }

    private func event(_ edit: (inout [String: Any]) -> Void) throws -> Event {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: exampleLines()[0]) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testV01ExamplesMigrateToV02AndRoundTrip() throws {
        let lines = try exampleLines()
        XCTAssertEqual(lines.count, 12)
        for line in lines {
            let event = try JSONDecoder().decode(Event.self, from: line)
            XCTAssertEqual(event.schemaVersion, "0.2", event.id)
            XCTAssertEqual(event.validate(), [], event.id)
            XCTAssertEqual(event.direction, event.sender == "me" ? .outgoing : .incoming, event.id)
            XCTAssertNil(event.senderContact)
            XCTAssertEqual(event.recipients, [])
            // Everything v0.1 said is unchanged; v0.2 only adds fields.
            var original = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
            var written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
            for key in ["direction", "sender_handle", "recipients", "sender_contact"] {
                XCTAssertNotNil(written.removeValue(forKey: key), key)
            }
            original["schema_version"] = "0.2"
            XCTAssertEqual(
                try normalized(JSONSerialization.data(withJSONObject: written)),
                try normalized(JSONSerialization.data(withJSONObject: original)),
                event.id
            )
            // And v0.2 round-trips exactly.
            let again = try JSONDecoder().decode(Event.self, from: JSONEncoder().encode(event))
            XCTAssertEqual(again, event)
        }
    }

    func testMigrationTakesHandlesOnlyFromWhatV01Said() throws {
        let message = try event { _ in }
        XCTAssertEqual(message.senderHandle, "Alex Example") // v0.1 put the Messages handle in sender
        let own = try event { $0["sender"] = "me" }
        XCTAssertEqual(own.direction, .outgoing)
        XCTAssertNil(own.senderHandle)
        XCTAssertEqual(emailAddress(in: "Jordan Sample <jordan@example.com>"), "jordan@example.com")
        XCTAssertEqual(emailAddress(in: "jordan@example.com"), "jordan@example.com")
        XCTAssertNil(emailAddress(in: "Jordan Sample"))
        XCTAssertNil(emailAddress(in: "Jordan <not an address>"))
    }

    func testEventIDsMatchStageZero() throws {
        for line in try exampleLines() {
            let event = try JSONDecoder().decode(Event.self, from: line)
            XCTAssertEqual(EventID.make(source: event.source, sourceRecordID: event.sourceRecordID), event.id)
        }
        XCTAssertEqual(EventID.make(source: .imessage, sourceRecordID: "B6E0F0A1-0000-4000-8000-000000000001"), "ev_f403382210fbc3b8")
        XCTAssertTrue(EventID.isWellFormed("ev_f403382210fbc3b8"))
        for bad in ["ev_F403382210FBC3B8", "ev_f403382210fbc3b", "xx_f403382210fbc3b8", "ev_f403382210fbc3b8a"] {
            XCTAssertFalse(EventID.isWellFormed(bad), bad)
        }
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256.hex([]), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(Array("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            SHA256.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        XCTAssertEqual(SHA256.hex([UInt8](repeating: 0x61, count: 1000)).prefix(16), "41edece42d63e8d9")
    }

    func testContractTimeParsesAndWritesTheOneFormat() throws {
        for text in [
            "2026-10-06T07:12:00Z",
            "1969-12-31T23:59:59Z",
            "2001-01-01T00:00:00Z",
            "2024-02-29T12:00:00Z",
            "2026-10-06T07:12:01.5Z",
        ] {
            XCTAssertEqual(try ContractTime.format(XCTUnwrap(ContractTime.parse(text), text)), text)
        }
        XCTAssertEqual(ContractTime.parse("2001-01-01T00:00:00Z")?.timeIntervalSince1970, 978_307_200)
        XCTAssertEqual(ContractTime.parse("2026-10-06T07:12:01.250Z").map(ContractTime.format), "2026-10-06T07:12:01.25Z")
        let bad = [
            "2026-02-30T00:00:00Z", "2023-02-29T00:00:00Z", "2026-10-06T24:00:00Z", "2026-10-06T07:60:00Z",
            "2026-10-06 07:12:00Z", "2026-10-06T07:12:00", "2026-10-06T07:12:00+00:00", "2026-10-06T07:12:00.Z", "", "x",
        ]
        for text in bad {
            XCTAssertNil(ContractTime.parse(text), text)
        }
    }

    func testEventValidationRules() throws {
        XCTAssertEqual(
            try event { $0["id"] = "ev_0000000000000000" }.validate(),
            ["/id: does not match event_id(source, source_record_id)"]
        )
        XCTAssertEqual(try event { $0["id"] = "EV_1" }.validate(), ["/id: does not match ^ev_[0-9a-f]{16}$"])
        for bare in ["12345", "-7", "+42"] {
            XCTAssertEqual(try event { $0["source_record_id"] = bare }.validate().first, "/source_record_id: must not be a bare number")
        }
        XCTAssertEqual(try event { $0["source_record_id"] = "" }.validate().first, "/source_record_id: shorter than 1")
        XCTAssertEqual(try event { $0["flags"] = ["edited", "edited"] }.validate(), ["/flags: items must be unique"])
        XCTAssertEqual(try event { $0["observations"] = [] }.validate(), ["/observations: needs at least 1 item(s)"])
        let foreign: [[String: Any]] = [[
            "route": "notification_db",
            "source_record_id": "9D4F2C10-0000-4000-8000-0000000000A1",
            "capture_time": "2026-10-06T07:12:01Z",
        ]]
        XCTAssertEqual(
            try event { $0["observations"] = foreign }.validate(),
            ["/observations: none is the event's own source record from a matching route"]
        )
    }

    func testDecodingIsStrictLikeTheSchema() throws {
        XCTAssertThrowsError(try event { $0["surprise"] = 1 })
        XCTAssertThrowsError(try event { $0.removeValue(forKey: "app_id") }) // nullable, but required
        XCTAssertThrowsError(try event { $0["event_time"] = "2026-10-06T07:12:00+00:00" })
        XCTAssertThrowsError(try event { $0["source"] = "whatsapp" })
        XCTAssertThrowsError(try event { $0["direction"] = "incoming" }, "a v0.1 document can't carry v0.2 fields")
        XCTAssertThrowsError(try event { $0["schema_version"] = "0.3" }, "unknown versions fail clearly")
        XCTAssertNil(try event { $0["app_id"] = NSNull() }.appID)
        let encoded = try normalized(JSONEncoder().encode(event { $0["title"] = NSNull() }))
        XCTAssertTrue(encoded.contains("\"title\":null"), "nil must be written as null, as the contract requires")
    }

    func testV02PartyRules() throws {
        let base = try event { _ in }
        var outgoingStranger = base
        outgoingStranger.direction = .outgoing
        XCTAssertEqual(outgoingStranger.validate(), ["/direction: outgoing exactly when sender is \"me\""])
        var outgoingNotification = try event { $0["sender"] = "me"; $0["source"] = "imessage" }
        outgoingNotification.source = .notification
        XCTAssertTrue(outgoingNotification.validate().contains("/direction: a notification is never outgoing"))
        var parties = base
        parties.recipients = ["+61400000001", "+61400000001", ""]
        parties.senderHandle = ""
        XCTAssertEqual(parties.validate(), [
            "/sender_handle: shorter than 1", "/recipients: items must not be empty", "/recipients: items must be unique",
        ])
        var ambiguous = base
        ambiguous.flags = [.ambiguousSender]
        ambiguous.senderContact = Event.ContactRef(id: "C1", name: "Alex Example")
        XCTAssertEqual(ambiguous.validate(), ["/sender_contact: must be null when the sender is ambiguous"])
        ambiguous.senderContact = nil
        XCTAssertEqual(ambiguous.validate(), [])
        var resolved = base
        resolved.senderContact = Event.ContactRef(id: "", name: "Alex")
        XCTAssertEqual(resolved.validate(), ["/sender_contact: id and name must not be empty"])
    }

    func testScheduleRecordsRoundTripAndValidate() throws {
        let start = try XCTUnwrap(ContractTime.parse("2026-10-09T09:00:00Z"))
        let captured = try XCTUnwrap(ContractTime.parse("2026-10-09T06:00:00Z"))
        let meeting = CalendarOccurrence(
            itemID: "ITEM-1", occurrenceDate: start, calendarTitle: "Work", title: "Standup", start: start,
            end: start.addingTimeInterval(900), isAllDay: false, timeZone: "Australia/Brisbane", location: nil,
            status: .confirmed, captureTime: captured
        )
        XCTAssertEqual(meeting.validate(), [])
        XCTAssertEqual(try JSONDecoder().decode(CalendarOccurrence.self, from: JSONEncoder().encode(meeting)), meeting)
        let nextWeek = CalendarOccurrence(
            itemID: "ITEM-1", occurrenceDate: start.addingTimeInterval(7 * 86400), calendarTitle: "Work", title: "Standup",
            start: start.addingTimeInterval(7 * 86400), end: start.addingTimeInterval(7 * 86400 + 900), isAllDay: false,
            timeZone: "Australia/Brisbane", location: nil, status: .confirmed, captureTime: captured
        )
        XCTAssertNotEqual(meeting.id, nextWeek.id, "each occurrence of a repeating event has its own ID")
        XCTAssertTrue(meeting.id.hasPrefix("cal_"))
        var backwards = meeting
        backwards.end = start.addingTimeInterval(-1)
        XCTAssertEqual(backwards.validate(), ["/end: before start"])
        var moved = meeting
        moved.start = start.addingTimeInterval(3600)
        moved.end = moved.start.addingTimeInterval(900)
        XCTAssertEqual(moved.validate(), [], "moving one occurrence keeps its ID (DeepSeek, #53)")
        var renumbered = meeting
        renumbered.occurrenceDate = start.addingTimeInterval(86400)
        XCTAssertEqual(renumbered.validate(), ["/id: does not match occurrence(item_id, occurrence_date)"])

        let task = ReminderItem(
            itemID: "REM-1", listTitle: "Home", title: "Pay invoice",
            due: .init(date: start, hasTime: false, timeZone: "Australia/Brisbane"), isCompleted: false, completedAt: nil,
            priority: 1, captureTime: captured
        )
        XCTAssertEqual(task.validate(), [])
        XCTAssertEqual(try JSONDecoder().decode(ReminderItem.self, from: JSONEncoder().encode(task)), task)
        var odd = task
        odd.priority = 12
        odd.completedAt = captured
        XCTAssertEqual(odd.validate(), ["/priority: must be 0 to 9", "/completed_at: must be null while not completed"])
        var extra = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        extra["action"] = "mark done"
        XCTAssertThrowsError(try JSONDecoder().decode(ReminderItem.self, from: JSONSerialization.data(withJSONObject: extra)))
    }

    func testOccurrenceIdentityFollowsTheOriginalDate() throws {
        let start = try XCTUnwrap(ContractTime.parse("2026-10-06T22:00:00Z"))
        let captured = try XCTUnwrap(ContractTime.parse("2026-10-06T21:05:00Z"))
        func single(at time: Date) -> CalendarOccurrence {
            CalendarOccurrence(
                itemID: "ONE-OFF", occurrenceDate: nil, calendarTitle: nil, title: "Dentist", start: time,
                end: time.addingTimeInterval(1800), isAllDay: false, timeZone: "Australia/Sydney", location: nil,
                status: .confirmed, captureTime: captured
            )
        }
        let single1 = single(at: start)
        XCTAssertEqual(single1.id, single(at: start.addingTimeInterval(7200)).id, "a moved single event keeps its ID")
        XCTAssertEqual(single1.id, ScheduleID.occurrence(itemID: "ONE-OFF", occurrenceDate: nil))
        XCTAssertNotEqual(single1.id, ScheduleID.occurrence(itemID: "ONE-OFF", occurrenceDate: start))

        // The key matches the fixture generator's: item, or item + U+001F + the contract timestamp, SHA-256, 16 hex.
        let key = Array("ITEM-1\u{1F}2026-10-06T22:00:00Z".utf8)
        XCTAssertEqual(ScheduleID.occurrence(itemID: "ITEM-1", occurrenceDate: start), "cal_" + SHA256.hex(key).prefix(16))

        // occurrence_date is always written, as null for a single event, and a record without it is rejected.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(single1)) as? [String: Any])
        XCTAssertTrue(json["occurrence_date"] is NSNull)
        var missing = json
        missing.removeValue(forKey: "occurrence_date")
        XCTAssertThrowsError(
            try JSONDecoder().decode(CalendarOccurrence.self, from: JSONSerialization.data(withJSONObject: missing))
        )

        // A floating all-day occurrence keeps its date when the Mac changes time zone (case 27, travel).
        let brisbane = try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))
        let perth = try XCTUnwrap(TimeZone(identifier: "Australia/Perth"))
        let inBrisbane = try XCTUnwrap(ContractTime.parse("2026-10-05T14:00:00Z")) // 6 Oct 00:00 in Brisbane
        let inPerth = try XCTUnwrap(ContractTime.parse("2026-10-05T16:00:00Z")) // 6 Oct 00:00 in Perth
        let fromBrisbane = ScheduleID.floatingOccurrenceDate(inBrisbane, in: brisbane)
        XCTAssertEqual(fromBrisbane, ScheduleID.floatingOccurrenceDate(inPerth, in: perth))
        XCTAssertEqual(ContractTime.format(fromBrisbane), "2026-10-06T00:00:00Z")
    }

    func testExampleBriefAndRules() throws {
        let data = try Data(contentsOf: Self.examples.appendingPathComponent("brief.json"))
        let brief = try JSONDecoder().decode(Brief.self, from: data)
        let known = try Set(exampleLines().map { try JSONDecoder().decode(Event.self, from: $0).id })
        XCTAssertEqual(brief.validate(knownEventIDs: known), [])
        XCTAssertEqual(try normalized(JSONEncoder().encode(brief)), try normalized(data))

        var unknown = brief
        unknown.items[0].eventIDs = ["ev_0000000000000000"]
        XCTAssertEqual(unknown.validate(knownEventIDs: known), ["/items/0/event_ids: unknown event ev_0000000000000000"])
        var backwards = brief
        backwards.windowStart = backwards.windowEnd.addingTimeInterval(1)
        XCTAssertEqual(backwards.validate(knownEventIDs: known), ["/window_start: after window_end"])
        var malformed = brief
        malformed.items[0].text = ""
        malformed.items[0].eventIDs = ["ev_1", "ev_1"]
        malformed.omittedEvents = -1
        XCTAssertEqual(malformed.validate(knownEventIDs: known), [
            "/omitted_events: below 0", "/items/0/text: shorter than 1", "/items/0/event_ids: items must be unique",
            "/items/0/event_ids/0: does not match ^ev_[0-9a-f]{16}$", "/items/0/event_ids/1: does not match ^ev_[0-9a-f]{16}$",
        ])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["actions"] = ["unlock the door"]
        XCTAssertThrowsError(
            try JSONDecoder().decode(Brief.self, from: JSONSerialization.data(withJSONObject: object)),
            "a brief can't carry actions"
        )
    }
}
