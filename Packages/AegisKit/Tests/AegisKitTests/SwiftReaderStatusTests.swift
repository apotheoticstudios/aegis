@testable import AegisKit
import CSQLite
import Foundation
import XCTest
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class SwiftReaderStatusTests: XCTestCase {
    func testReadOnlyEmptyMissingAndUnreadableStores() throws {
        let fixtures = try SwiftReaderFixtures(self)
        let empty = try SwiftReaderFixtures(self, profile: "empty")
        for (source, emptyPath, reader) in [
            (fixtures.notifications, empty.notifications, NotificationReader.iterate),
            (fixtures.messages, empty.messages, MessagesReader.iterate),
        ] {
            let path = try readerCopy(source)
            let before = try readerSnapshot(path)
            let result = try ReaderBase.scan(path, reader: reader, now: fixtures.now)
            XCTAssertEqual(result.status.code, .ok)
            XCTAssertEqual(try readerSnapshot(path), before)
            XCTAssertEqual(try ReaderBase.scan(emptyPath, reader: reader).status, SourceStatus(ok: true, code: .noData))
            let missing = try syntheticReaderFolder().appendingPathComponent("missing")
            XCTAssertEqual(try ReaderBase.scan(missing, reader: reader).status, SourceStatus(ok: false, code: .notFound))
            let garbage = try syntheticReaderFolder().appendingPathComponent("garbage")
            try Data(repeating: 120, count: 256).write(to: garbage)
            XCTAssertEqual(try ReaderBase.scan(garbage, reader: reader).status, SourceStatus(ok: false, code: .unreadable))
        }
    }

    func testRevokedAndRestoredAccessAndUnableToOpen() throws {
        let fixtures = try SwiftReaderFixtures(self)
        for (path, reader) in [(fixtures.notifications, NotificationReader.iterate), (fixtures.messages, MessagesReader.iterate)] {
            var access = StoreAccess()
            access.header = { _ in throw StoreUnavailable(code: .permissionDenied) }
            XCTAssertEqual(
                try ReaderBase.scan(path, reader: reader, access: access).status,
                SourceStatus(ok: false, code: .permissionDenied)
            )
            XCTAssertEqual(try ReaderBase.scan(path, reader: reader).status.code, .ok)
            access = StoreAccess()
            access.connect = { _, _ in throw SQLiteError(code: SQLITE_CANTOPEN) }
            XCTAssertEqual(
                try ReaderBase.scan(path, reader: reader, access: access).status,
                SourceStatus(ok: false, code: .permissionDenied)
            )
        }
    }

    func testFilePermissionsAndLockedStore() throws {
        let fixtures = try SwiftReaderFixtures(self)
        if geteuid() != 0 {
            let path = try readerCopy(fixtures.notifications)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
            XCTAssertEqual(try NotificationReader.read(path).status.code, .permissionDenied)
        }
        let path = try readerCopy(fixtures.messages)
        let writer = try SyntheticWriter(path)
        try writer.execute("BEGIN EXCLUSIVE")
        XCTAssertEqual(try MessagesReader.read(path, busyTimeout: 0.01).status, SourceStatus(ok: false, code: .busy))
        try writer.execute("ROLLBACK")
        writer.close()
        XCTAssertEqual(try MessagesReader.read(path).status.code, .ok)
    }

    func testWALConcurrentWriterAndCommittedLogWithoutSHM() throws {
        let fixtures = try SwiftReaderFixtures(self)
        let path = try readerCopy(fixtures.notifications)
        let writer = try SyntheticWriter(path)
        try writer.execute("PRAGMA wal_autocheckpoint = 0; BEGIN")
        let stamp = fixtures.now.timeIntervalSinceReferenceDate
        try writer.execute("""
        INSERT INTO record (app_id, uuid, data, request_date, delivered_date)
        SELECT app_id, x'00000000000000000000000000000001', data, \(stamp), \(stamp) FROM record WHERE rec_id = 1
        """)
        XCTAssertEqual(try NotificationReader.read(path, now: fixtures.now).status.count, 11)
        try writer.execute("COMMIT")
        XCTAssertEqual(try NotificationReader.read(path, now: fixtures.now).status.count, 12)
        let snapshot = try readerCopy(path)
        try FileManager.default.copyItem(atPath: path.path + "-wal", toPath: snapshot.path + "-wal")
        writer.close()
        let before = try readerSnapshot(snapshot)
        let result = try NotificationReader.read(snapshot, now: fixtures.now)
        XCTAssertEqual(result.status.count, 12)
        XCTAssertTrue(result.events.contains { $0.sourceRecordID == "00000000-0000-0000-0000-000000000001" })
        XCTAssertEqual(try readerSnapshot(snapshot), before)
    }

    func testStoreReplacedAndChangingDuringCopy() throws {
        let fixtures = try SwiftReaderFixtures(self)
        let replacement = try SwiftReaderFixtures(self, seed: 42)
        let path = try readerCopy(fixtures.notifications)
        let first = try NotificationReader.read(path, now: fixtures.now).events
        try FileManager.default.removeItem(at: path)
        try FileManager.default.copyItem(at: replacement.notifications, to: path)
        let second = try NotificationReader.read(path, now: fixtures.now).events
        try assertReaderEvents(second, replacement.expected("notifications"))
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
        var access = StoreAccess()
        let copy = access.copy
        access.copy = { source, target in
            try copy(source, target)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: source.path)
        }
        XCTAssertEqual(
            try ReaderBase.scan(path, reader: NotificationReader.iterate, access: access).status,
            SourceStatus(ok: false, code: .busy)
        )
    }

    func testUnknownSchemasReportFormatChanged() throws {
        for (sql, reader) in [
            (
                "CREATE TABLE app (app_id INTEGER, identifier TEXT); CREATE TABLE record (uuid BLOB, data BLOB)",
                NotificationReader.iterate
            ),
            ("CREATE TABLE message (guid TEXT, text TEXT)", MessagesReader.iterate),
        ] {
            let path = try syntheticReaderFolder().appendingPathComponent("store")
            let writer = try SyntheticWriter(path)
            try writer.execute(sql)
            writer.close()
            let result = try ReaderBase.scan(path, reader: reader)
            XCTAssertEqual(result.status, SourceStatus(ok: false, code: .formatChanged))
            XCTAssertTrue(result.events.isEmpty)
        }
    }

    func testStreamingMatchesCollectionAndCallbackErrorsPropagate() throws {
        enum Stopped: Error { case requested }
        let fixtures = try SwiftReaderFixtures(self)
        for (path, reader) in [(fixtures.notifications, NotificationReader.iterate), (fixtures.messages, MessagesReader.iterate)] {
            let collected = try ReaderBase.scan(path, reader: reader, now: fixtures.now)
            var events: [Event] = []
            var problems: [ReadProblem] = []
            let streamed = try ReaderBase.scan(path, reader: reader, now: fixtures.now, onItem: { item in
                switch item {
                case let .event(event): events.append(event)
                case let .problem(problem): problems.append(problem)
                }
            })
            XCTAssertEqual(streamed.status, collected.status)
            XCTAssertTrue(streamed.events.isEmpty)
            XCTAssertTrue(streamed.problems.isEmpty)
            XCTAssertEqual(events, collected.events)
            XCTAssertEqual(problems, collected.problems)
            XCTAssertThrowsError(try ReaderBase.scan(path, reader: reader, onItem: { _ in throw Stopped.requested })) {
                XCTAssertTrue($0 is Stopped)
            }
        }
    }

    func testStreamingTwentyThousandMessagesKeepsMemoryFlat() throws {
        let fixtures = try SwiftReaderFixtures(self, profile: "empty")
        let writer = try SyntheticWriter(fixtures.messages)
        let stamp = Int64(fixtures.now.timeIntervalSinceReferenceDate) * 1_000_000_000
        try writer.execute("""
        INSERT INTO handle (id, service) VALUES ('synthetic@example.com', 'iMessage');
        INSERT INTO chat (guid, display_name) VALUES ('iMessage;-;synthetic@example.com', '');
        WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 20000)
        INSERT INTO message (guid, text, handle_id, service, date)
        SELECT 'BULK-' || n, replace(hex(zeroblob(1024)), '0', 'x'), 1, 'iMessage', \(stamp) + n * 1000000000 FROM numbers;
        INSERT INTO chat_message_join SELECT 1, ROWID, date FROM message;
        """)
        writer.close()
        _ = try MessagesReader.read(
            fixtures.messages,
            now: fixtures.now,
            since: fixtures.now.addingTimeInterval(19000),
            onItem: { _ in }
        )
        let before = try peakMemoryBytes()
        var count = 0
        let result = try MessagesReader.read(fixtures.messages, now: fixtures.now, onItem: { item in
            guard case let .event(event) = item else { return XCTFail("unexpected bulk record problem") }
            XCTAssertEqual(event.body.utf8.count, 2048)
            count += 1
        })
        let growth = try peakMemoryBytes() - before
        XCTAssertEqual(count, 20000)
        XCTAssertEqual(result.status, SourceStatus(ok: true, code: .ok, count: 20000))
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertLessThan(growth, 8 * 1024 * 1024, "streaming must not retain the roughly 40 MB of row bodies")
    }
}
