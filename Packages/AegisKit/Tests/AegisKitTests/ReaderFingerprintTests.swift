@testable import AegisKit
import CSQLite
import Foundation
import XCTest

final class ReaderFingerprintTests: XCTestCase {
    func testDriftForAllReadersEmitsNothingAndDoesNotCheckpoint() async throws {
        let fixtures = try SwiftReaderFixtures(self, profile: "drift")
        // The generator's frozen drift profile changes Mail only. Extend its synthetic copies locally.
        for (path, sql) in [
            (fixtures.notifications, "ALTER TABLE record RENAME COLUMN data TO changed_data"),
            (fixtures.messages, "ALTER TABLE message RENAME COLUMN attributedBody TO changed_body"),
        ] {
            let writer = try SyntheticWriter(path)
            try writer.execute(sql)
            writer.close()
        }
        let collectors = [
            ReaderCollector.notifications(at: fixtures.notifications),
            ReaderCollector.messages(at: fixtures.messages),
            ReaderCollector.mail(at: fixtures.root.appendingPathComponent("mail")),
        ]
        for collector in collectors {
            let batch = try await collector.collect(after: nil, now: fixtures.now)
            XCTAssertEqual(batch.status, SourceStatus(ok: false, code: .formatChanged))
            XCTAssertTrue(batch.events.isEmpty)
            XCTAssertNil(batch.checkpoint)
        }
    }

    func testAllRequiredNotificationAndMessagesTablesAreCheckedBeforeStreaming() throws {
        let fixtures = try SwiftReaderFixtures(self)
        let checks: [(URL, (ReaderBase.Reader, String))] = [
            (fixtures.notifications, (NotificationReader.iterate, "app")),
            (fixtures.notifications, (NotificationReader.iterate, "record")),
            (fixtures.messages, (MessagesReader.iterate, "message")),
            (fixtures.messages, (MessagesReader.iterate, "handle")),
            (fixtures.messages, (MessagesReader.iterate, "chat")),
            (fixtures.messages, (MessagesReader.iterate, "chat_message_join")),
        ]
        for (original, (reader, table)) in checks {
            let path = try readerCopy(original)
            let writer = try SyntheticWriter(path)
            try writer.execute("DROP TABLE \(table)")
            writer.close()
            var emitted = 0
            let result = try ReaderBase.scan(path, reader: reader, onItem: { _ in emitted += 1 })
            XCTAssertEqual(result.status, SourceStatus(ok: false, code: .formatChanged))
            XCTAssertEqual(emitted, 0)
        }
    }

    func testMailMetadataFingerprintFailsBeforeOpeningBodyFiles() throws {
        let fixtures = try SwiftReaderFixtures(self)
        let original = fixtures.root.appendingPathComponent("mail/V10/MailData/Envelope Index")
        for table in ["subjects", "addresses", "mailboxes"] {
            let path = try readerCopy(original)
            let writer = try SyntheticWriter(path)
            try writer.execute("DROP TABLE \(table)")
            writer.close()
            var access = MailAccess()
            access.listFiles = { _, _ in XCTFail("drift must not open body files") }
            let result = try MailReader.read(path, access: access)
            XCTAssertEqual(result.status, SourceStatus(ok: false, code: .formatChanged))
            XCTAssertTrue(result.events.isEmpty)
        }
    }

    func testSQLitePermissionFailuresUseTheExistingPermissionCode() throws {
        let fixtures = try SwiftReaderFixtures(self)
        for code in [SQLITE_PERM, SQLITE_AUTH, SQLITE_READONLY] {
            let result = try ReaderBase.scan(fixtures.messages, reader: { _, _, _, _ in
                throw SQLiteError(code: code)
            })
            XCTAssertEqual(result.status, SourceStatus(ok: false, code: .permissionDenied))
        }
    }

    func testLegacyReaderSchemaErrorsBecomeCollectorStatus() async throws {
        let collector = ReaderCollector(source: .messages, path: URL(fileURLWithPath: "/synthetic/unused")) { _, _, _ in
            throw UnknownSchemaError(table: "message", found: [])
        }
        let batch = try await collector.collect(after: nil, now: Date())
        XCTAssertEqual(batch.status.code, .formatChanged)
        XCTAssertNil(batch.checkpoint)
    }
}
