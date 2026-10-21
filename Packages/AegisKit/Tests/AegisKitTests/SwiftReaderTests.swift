@testable import AegisKit
import Foundation
import XCTest

final class SwiftReaderTests: XCTestCase {
    func testFixtureParityForSeedsSevenAndFortyTwoAndDrift() throws {
        for (seed, profile) in [(7, "full"), (42, "full"), (7, "drift")] {
            let fixtures = try SwiftReaderFixtures(self, seed: seed, profile: profile)
            for (path, reader, name, sources) in [
                (fixtures.notifications, NotificationReader.iterate, "notifications", Set(["notification"])),
                (fixtures.messages, MessagesReader.iterate, "messages", Set(["imessage", "sms"])),
            ] {
                let result = try ReaderBase.scan(path, reader: reader, now: fixtures.now)
                let expected = try fixtures.expected(name)
                XCTAssertEqual(result.status, SourceStatus(ok: true, code: .ok, count: expected.count, problems: result.problems.count))
                assertReaderEvents(result.events, expected)
                try assertReaderProblems(result.problems, fixtures.expectedProblems(sources))
            }
        }
    }

    func testTextUnknownsPartiesAndCrossRouteTwins() throws {
        let fixtures = try SwiftReaderFixtures(self)
        let notes = try NotificationReader.read(fixtures.notifications, now: fixtures.now).events
        let messages = try MessagesReader.read(fixtures.messages, now: fixtures.now).events
        let events = notes + messages
        XCTAssertTrue(events.contains { $0.body == "\u{0000}\u{200B}hidden characters" })
        let nfd = try XCTUnwrap(notes.first { $0.title?.utf8.starts(with: "Jose".utf8) == true }?.title)
        XCTAssertNotEqual(Array(nfd.utf8), Array(nfd.precomposedStringWithCanonicalMapping.utf8))
        let injections = try (fixtures.expected("notifications") + fixtures.expected("messages"))
            .filter { $0.title == "Aegis" || $0.body.contains("assistant") }
        XCTAssertFalse(injections.isEmpty)
        for injection in injections {
            XCTAssertTrue(events.contains { $0.body == injection.body })
        }
        XCTAssertNil(try XCTUnwrap(notes.first { $0.body == "Arrays where strings belong" }).title)
        XCTAssertNil(try XCTUnwrap(notes.first { $0.title == "Orphan app" }).appID)
        XCTAssertNil(try XCTUnwrap(messages.first { $0.body == "A message with no chat" }).threadID)
        XCTAssertNil(try XCTUnwrap(messages.first { $0.body == "Sender row missing" }).sender)
        XCTAssertTrue(messages.contains { $0.threadID?.contains(";-;") == true })
        XCTAssertTrue(messages.contains { $0.threadID?.contains(";+;") == true })
        for event in events {
            XCTAssertEqual(event.direction, event.sender == "me" ? .outgoing : .incoming)
            XCTAssertEqual(event.senderHandle, event.source == .notification || event.sender == "me" ? nil : event.sender)
            XCTAssertEqual(event.recipients, [])
            XCTAssertNil(event.senderContact)
        }
        let twins = try JSONDecoder().decode(
            [[String: String]].self, from: Data(contentsOf: fixtures.root.appendingPathComponent("expected/duplicates.json"))
        )
        XCTAssertEqual(twins.count, 2)
        let ids = Set(events.map(\.id))
        for twin in twins {
            XCTAssertTrue(try ids.contains(XCTUnwrap(twin["notification_event"])))
            XCTAssertTrue(try ids.contains(XCTUnwrap(twin["message_event"])))
        }
    }

    func testWindowAndCaptureTimeIncludingSecondBasedDates() throws {
        let fixtures = try SwiftReaderFixtures(self)
        let since = fixtures.now.addingTimeInterval(-13 * 3600)
        for (path, reader, name) in [
            (fixtures.notifications, NotificationReader.iterate, "notifications"),
            (fixtures.messages, MessagesReader.iterate, "messages"),
        ] {
            let expected = try fixtures.expected(name)
            let recent = expected.filter { $0.eventTime >= since }
            XCTAssertFalse(recent.isEmpty)
            XCTAssertLessThan(recent.count, expected.count)
            try assertReaderEvents(ReaderBase.scan(path, reader: reader, now: fixtures.now, since: since).events, recent)
        }
        let path = try readerCopy(fixtures.messages)
        let writer = try SyntheticWriter(path)
        try writer.execute("UPDATE message SET date = date / 1000000000 WHERE date > 100000000000000")
        writer.close()
        try assertReaderEvents(
            MessagesReader.read(path, now: fixtures.now, since: since).events,
            MessagesReader.read(fixtures.messages, now: fixtures.now, since: since).events
        )
        let later = fixtures.now.addingTimeInterval(300.75)
        for (path, reader) in [(fixtures.notifications, NotificationReader.iterate), (fixtures.messages, MessagesReader.iterate)] {
            let event = try XCTUnwrap(ReaderBase.scan(path, reader: reader, now: later).events.first)
            XCTAssertEqual(event.captureTime, fixtures.now.addingTimeInterval(300))
            XCTAssertEqual(event.observations.first?.captureTime, event.captureTime)
        }
    }

    func testOptionalColumnsSystemRowsUnsentAndAssociationBoundaries() throws {
        let fixtures = try SwiftReaderFixtures(self)
        let writer = try SyntheticWriter(fixtures.messages)
        try writer.execute("ALTER TABLE message ADD COLUMN item_type INTEGER DEFAULT 0")
        try writer.execute("ALTER TABLE message ADD COLUMN is_system_message INTEGER DEFAULT 0")
        let stamp = Int64(fixtures.now.timeIntervalSinceReferenceDate) * 1_000_000_000
        var expectedProblems: [ReadProblem] = []
        let surviving: Set = ["PARTLY-UNSENT", "ASSOC-1999", "ASSOC-4001"]
        for kind in [1000, 1999, 2000, 2007, 2999, 3000, 3007, 3999, 4000, 4001] {
            let guid = "ASSOC-\(kind)"
            try writer.execute("""
            INSERT INTO message (guid, text, handle_id, service, date, associated_message_type)
            VALUES ('\(guid)', 'Still here', 1, 'iMessage', \(stamp), \(kind))
            """)
            if !surviving.contains(guid) {
                expectedProblems.append(ReadProblem(
                    code: "reaction_skipped",
                    source: "imessage",
                    record: guid,
                    note: "associated_message_type \(kind)"
                ))
            }
        }
        try addSystemAndUnsentRows(writer, stamp: stamp, expectedProblems: &expectedProblems)
        writer.close()
        let result = try MessagesReader.read(fixtures.messages, now: fixtures.now)
        let original = try fixtures.expected("messages")
        let originalIDs = Set(original.map(\.sourceRecordID))
        XCTAssertEqual(Set(result.events.filter { !originalIDs.contains($0.sourceRecordID) }.map(\.sourceRecordID)), surviving)
        assertReaderEvents(result.events.filter { originalIDs.contains($0.sourceRecordID) }, original)
        XCTAssertEqual(
            result.problems.filter { $0.record.hasPrefix("ASSOC-") || $0.record.hasPrefix("SYS-")
                || ["SYSTEM-FLAG", "UNSENT"].contains($0.record)
            }.sorted { $0.record < $1.record },
            expectedProblems.sorted { $0.record < $1.record }
        )
    }

    private func addSystemAndUnsentRows(_ writer: SyntheticWriter, stamp: Int64, expectedProblems: inout [ReadProblem]) throws {
        for kind in 1 ... 6 {
            try writer.execute("""
            INSERT INTO message (guid, handle_id, service, date, item_type)
            VALUES ('SYS-\(kind)', 1, 'iMessage', \(stamp), \(kind))
            """)
            expectedProblems.append(ReadProblem(
                code: "system_item_skipped",
                source: "imessage",
                record: "SYS-\(kind)",
                note: "item_type \(kind)"
            ))
        }
        try writer.execute("""
        INSERT INTO message (guid, text, handle_id, service, date, is_system_message, date_retracted) VALUES
        ('SYSTEM-FLAG', NULL, 1, 'iMessage', \(stamp), 1, 0),
        ('UNSENT', NULL, 1, 'iMessage', \(stamp), 0, \(stamp)),
        ('PARTLY-UNSENT', 'Still here', 1, 'iMessage', \(stamp), 0, \(stamp));
        INSERT INTO chat_message_join SELECT 1, ROWID, date FROM message WHERE guid LIKE 'ASSOC-%'
        OR guid LIKE 'SYS-%' OR guid IN ('SYSTEM-FLAG', 'UNSENT', 'PARTLY-UNSENT');
        """)
        expectedProblems += [
            ReadProblem(code: "system_item_skipped", source: "imessage", record: "SYSTEM-FLAG", note: "item_type 0"),
            ReadProblem(code: "unsent_skipped", source: "imessage", record: "UNSENT"),
        ]
    }

    func testMessageTimestampProblemsTextPriorityAndSkewBoundary() throws {
        let fixtures = try SwiftReaderFixtures(self, profile: "empty")
        let writer = try SyntheticWriter(fixtures.messages)
        let seconds = Int64(fixtures.now.timeIntervalSinceReferenceDate)
        try writer.execute("""
        INSERT INTO handle (id, service) VALUES ('synthetic@example.com', 'iMessage');
        INSERT INTO chat (guid, display_name) VALUES ('iMessage;-;synthetic@example.com', '');
        INSERT INTO message (guid, text, attributedBody, handle_id, service, date, date_edited) VALUES
        ('ZERO', 'synthetic', NULL, 1, 'iMessage', 0, 0),
        ('NULL-DATE', 'synthetic', NULL, 1, 'iMessage', NULL, 0),
        ('TEXT-DATE', 'synthetic', NULL, 1, 'iMessage', 'not a number', 0),
        ('NEGATIVE', 'synthetic', NULL, 1, 'SMS', -1, 0),
        ('END-OF-RANGE', 'synthetic', NULL, 1, 'iMessage', 3124137600, 0),
        ('BOUNDARY', 'text wins', x'0102', 1, 'other', \(seconds + 600), 0),
        ('FUTURE', 'edited future', NULL, 1, 'SMS', \((seconds + 601) * 1_000_000_000), 1);
        INSERT INTO chat_message_join SELECT 1, ROWID, date FROM message;
        """)
        writer.close()
        let result = try MessagesReader.read(fixtures.messages, now: fixtures.now)
        XCTAssertEqual(result.events.map(\.sourceRecordID), ["BOUNDARY", "FUTURE"])
        XCTAssertEqual(result.events.first?.body, "text wins")
        XCTAssertEqual(result.events.first?.source, .imessage)
        XCTAssertEqual(result.events.first?.flags, [])
        XCTAssertEqual(result.events.last?.flags, [.edited, .clockSkew])
        XCTAssertEqual(result.events.last?.eventTime, fixtures.now.addingTimeInterval(601))
        assertReaderProblems(result.problems, [
            ReadProblem(code: "missing_timestamp", source: "imessage", record: "ZERO"),
            ReadProblem(code: "missing_timestamp", source: "imessage", record: "NULL-DATE"),
            ReadProblem(code: "missing_timestamp", source: "imessage", record: "TEXT-DATE"),
            ReadProblem(code: "timestamp_out_of_range", source: "sms", record: "NEGATIVE"),
            ReadProblem(code: "timestamp_out_of_range", source: "imessage", record: "END-OF-RANGE"),
        ])
    }

    func testOlderLayoutAndFirstChatOnly() throws {
        let fixtures = try SwiftReaderFixtures(self)
        let original = try fixtures.expected("messages")
        let writer = try SyntheticWriter(fixtures.messages)
        try writer.execute("""
        DELETE FROM message WHERE associated_message_type != 0;
        ALTER TABLE message RENAME TO message_new;
        CREATE TABLE message AS SELECT ROWID, guid, text, attributedBody, handle_id, service, date, is_from_me FROM message_new;
        DROP TABLE message_new;
        INSERT INTO chat_message_join SELECT 999, ROWID, date FROM message;
        INSERT INTO chat (ROWID, guid, display_name) VALUES (999, 'iMessage;+;second-chat', 'Second chat');
        """)
        writer.close()
        let result = try MessagesReader.read(fixtures.messages, now: fixtures.now)
        let expected = original.map { event in
            var event = event
            event.flags.removeAll { $0 == .edited }
            if event.threadID == nil {
                event.threadID = "iMessage;+;second-chat"
                event.title = "Second chat"
            }
            return event
        }
        assertReaderEvents(result.events, expected)
        XCTAssertFalse(result.events.contains { $0.flags.contains(.edited) })
    }

    func testNotificationMissingUUIDPendingDeliveryAndPayloadErrors() throws {
        let fixtures = try SwiftReaderFixtures(self)
        let writer = try SyntheticWriter(fixtures.notifications)
        let stamp = fixtures.now.timeIntervalSinceReferenceDate
        try writer.execute("""
        INSERT INTO record (uuid, data) VALUES (NULL, NULL), (x'0102', NULL);
        INSERT INTO record (uuid, data, request_date, delivered_date)
        SELECT x'00000000000000000000000000000001', data, \(stamp), 0 FROM record WHERE rec_id = 1;
        INSERT INTO record (uuid, data, request_date, delivered_date)
        SELECT x'00000000000000000000000000000002', data, -1000, NULL FROM record WHERE rec_id = 1;
        INSERT INTO record (uuid, data, request_date, delivered_date)
        VALUES (x'00000000000000000000000000000003', NULL, \(stamp), \(stamp));
        UPDATE app SET identifier = lower(identifier);
        """)
        writer.close()
        let result = try NotificationReader.read(fixtures.notifications, now: fixtures.now)
        let expected = try fixtures.expected("notifications").map { event in
            var event = event
            event.appID = event.appID?.lowercased()
            return event
        }
        assertReaderEvents(result.events, expected)
        XCTAssertEqual(result.problems.filter { $0.code == "missing_uuid" }.count, 2)
        XCTAssertEqual(result.problems.first { $0.record.hasSuffix("000000000001") }?.code, "not_delivered")
        XCTAssertEqual(result.problems.first { $0.record.hasSuffix("000000000002") }?.code, "missing_timestamp")
        XCTAssertEqual(result.problems.first { $0.record.hasSuffix("000000000003") }?.code, "bplist_parse_error")
        XCTAssertThrowsError(try NotificationReader.read(fixtures.notifications, now: fixtures.now, onItem: { item in
            if case let .problem(problem) = item, problem.record.hasSuffix("000000000003") {
                throw NotificationPayloadError.invalidPropertyList
            }
        })) { XCTAssertEqual($0 as? NotificationPayloadError, .invalidPropertyList) }
    }
}
