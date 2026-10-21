@testable import AegisKit
import CSQLite
import Foundation
import XCTest
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class ReaderBaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-synthetic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func database(
        in folder: URL, name: String = "store", wal: Bool = false, empty: Bool = false, missingSidecars: Bool = true
    ) throws -> URL {
        let path = folder.appendingPathComponent(name)
        let writer = try SyntheticWriter(path)
        defer { writer.close() }
        if wal {
            try writer.execute("PRAGMA journal_mode = WAL")
        }
        try writer.execute("CREATE TABLE records (guid TEXT, body TEXT)")
        if !empty {
            try writer.execute("INSERT INTO records VALUES ('synthetic-A', 'Synthetic body')")
        }
        writer.close()
        // macOS SQLite can persist empty sidecars after closing. Model the Stage 0 private-copy fixture.
        if wal, missingSidecars {
            for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: path.path + suffix) {
                try FileManager.default.removeItem(atPath: path.path + suffix)
            }
        }
        return path
    }

    private var reader: ReaderBase.Reader {
        { connection, now, _, emit in
            try connection.require("records", columns: ["guid", "body"])
            try connection.query("SELECT guid, body FROM records ORDER BY guid") { row in
                guard case let .text(record) = row["guid"], case let .text(body) = row["body"] else {
                    return try emit(.problem(ReadProblem(code: "bad_record", source: "imessage", record: "synthetic")))
                }
                try emit(.event(ReaderBase.makeEvent(
                    source: .imessage, sourceRecordID: record, eventTime: now, eventTimeSource: .sent,
                    captureTime: now, body: body, content: .complete, route: .chatDB
                )))
            }
        }
    }

    private func snapshot(_ folder: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            files[name] = try Data(contentsOf: folder.appendingPathComponent(name))
        }
        return files
    }

    func testReadingNeverCreatesOrChangesFiles() throws {
        for (wal, missing) in [(false, false), (true, false), (true, true)] {
            let folder = try folder()
            let path = try database(in: folder, name: "store ?#% synthetic", wal: wal, missingSidecars: missing)
            let before = try snapshot(folder)
            let result = try ReaderBase.scan(path, reader: reader, now: now)
            XCTAssertEqual(result.status, SourceStatus(ok: true, code: .ok, count: 1))
            XCTAssertEqual(try snapshot(folder), before)
            try ReaderBase.openReadOnly(path) { connection in
                XCTAssertThrowsError(try connection.execute("INSERT INTO records VALUES ('X', 'Y')")) {
                    XCTAssertEqual(($0 as? SQLiteError)?.primaryCode, SQLITE_READONLY)
                }
                var queryOnly: SQLiteValue?
                try connection.query("PRAGMA query_only") { queryOnly = $0.values.first }
                XCTAssertEqual(queryOnly, .integer(1))
            }
            XCTAssertEqual(try snapshot(folder), before)
        }
    }

    func testEmptyStoreIsNoData() throws {
        let path = try database(in: folder(), empty: true)
        let result = try ReaderBase.scan(path, reader: reader)
        XCTAssertEqual(result.status, SourceStatus(ok: true, code: .noData))
        XCTAssertTrue(result.events.isEmpty)
        // A readable zero-byte SQLite store with a reader that emits nothing is also no_data.
        let zero = path.deletingLastPathComponent().appendingPathComponent("zero")
        try Data().write(to: zero)
        XCTAssertEqual(try ReaderBase.scan(zero, reader: { _, _, _, _ in }).status.code, .noData)
    }

    func testMissingStoreIsNotFoundAndCreatesNothing() throws {
        let folder = try folder()
        let path = folder.appendingPathComponent("missing/store")
        XCTAssertEqual(try ReaderBase.scan(path, reader: reader).status, SourceStatus(ok: false, code: .notFound))
        XCTAssertTrue(try snapshot(folder).isEmpty)
        XCTAssertThrowsError(try ReaderBase.openReadOnly(path) { _ in }) {
            XCTAssertEqual($0 as? StoreUnavailable, StoreUnavailable(code: .notFound))
        }
    }

    func testAccessRevokedAndRestoredBetweenReads() throws {
        let path = try database(in: folder())
        XCTAssertEqual(try ReaderBase.scan(path, reader: reader).status.code, .ok)
        var access = StoreAccess()
        access.header = { _ in throw StoreUnavailable(code: .permissionDenied) }
        let denied = try ReaderBase.scan(path, reader: reader, access: access)
        XCTAssertEqual(denied.status, SourceStatus(ok: false, code: .permissionDenied))
        XCTAssertTrue(denied.events.isEmpty)
        XCTAssertEqual(try ReaderBase.scan(path, reader: reader).status.code, .ok)
    }

    func testUnreadableFileModeIsPermissionDenied() throws {
        guard geteuid() != 0 else { throw XCTSkip("root can read regardless of file mode") }
        let path = try database(in: folder())
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
        XCTAssertEqual(try ReaderBase.scan(path, reader: reader).status, SourceStatus(ok: false, code: .permissionDenied))
    }

    func testSQLiteUnableToOpenIsPermissionDenied() throws {
        let path = try database(in: folder())
        var access = StoreAccess()
        access.connect = { _, _ in throw SQLiteError(code: SQLITE_CANTOPEN) }
        let result = try ReaderBase.scan(path, reader: reader, access: access)
        XCTAssertEqual(result.status, SourceStatus(ok: false, code: .permissionDenied))
        // CANTOPEN can also occur when SQLite first reads the schema/WAL, after opening.
        XCTAssertEqual(try ReaderBase.scan(path, reader: { _, _, _, _ in
            throw SQLiteError(code: SQLITE_CANTOPEN)
        }).status.code, .permissionDenied)
    }

    func testLockedStoreIsBusyAndRecovers() throws {
        let path = try database(in: folder())
        let writer = try SyntheticWriter(path)
        defer { writer.close() }
        try writer.execute("BEGIN EXCLUSIVE")
        let started = Date()
        let result = try ReaderBase.scan(path, reader: reader, busyTimeout: 0.05)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.03)
        XCTAssertEqual(result.status, SourceStatus(ok: false, code: .busy))
        try writer.execute("ROLLBACK")
        XCTAssertEqual(try ReaderBase.scan(path, reader: reader).status.code, .ok)
    }

    func testConcurrentWriterInWALMode() throws {
        let path = try database(in: folder(), wal: true)
        let writer = try SyntheticWriter(path)
        defer { writer.close() }
        try writer.execute("BEGIN")
        try writer.execute("INSERT INTO records VALUES ('synthetic-B', 'Uncommitted synthetic body')")
        let before = try ReaderBase.scan(path, reader: reader)
        XCTAssertEqual(before.status.count, 1)
        try writer.execute("COMMIT")
        XCTAssertEqual(try ReaderBase.scan(path, reader: reader).status.count, 2)
    }

    func testStoreReplacedBetweenReads() throws {
        let folder = try folder()
        let path = try database(in: folder)
        let first = try ReaderBase.scan(path, reader: reader)
        let replacement = try database(in: folder, name: "replacement", empty: true)
        let writer = try SyntheticWriter(replacement)
        try writer.execute("INSERT INTO records VALUES ('synthetic-replaced', 'Replacement body')")
        writer.close()
        XCTAssertEqual(rename(replacement.path, path.path), 0)
        let second = try ReaderBase.scan(path, reader: reader)
        XCTAssertEqual(second.events.map(\.sourceRecordID), ["synthetic-replaced"])
        XCTAssertNotEqual(first.events.map(\.id), second.events.map(\.id))
    }

    func testCommittedChangesStillInWALAreRead() throws {
        let source = try database(in: folder(), wal: true)
        let snapshotFolder = try folder()
        let path = snapshotFolder.appendingPathComponent("snapshot")
        let writer = try SyntheticWriter(source)
        defer { writer.close() }
        try writer.execute("PRAGMA wal_autocheckpoint = 0")
        try writer.execute("INSERT INTO records VALUES ('synthetic-B', 'Only in the WAL')")
        try FileManager.default.copyItem(at: source, to: path)
        try FileManager.default.copyItem(atPath: source.path + "-wal", toPath: path.path + "-wal")
        let before = try snapshot(snapshotFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path + "-shm"))
        let result = try ReaderBase.scan(path, reader: reader)
        XCTAssertEqual(result.status.count, 2)
        XCTAssertEqual(result.events.last?.body, "Only in the WAL")
        XCTAssertEqual(try snapshot(snapshotFolder), before)
    }

    func testStoreChangingWhileCopiedIsBusy() throws {
        let path = try database(in: folder(), wal: true)
        var copies = 0
        var access = StoreAccess()
        let realCopy = access.copy
        access.copy = { source, target in
            try realCopy(source, target)
            copies += 1
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let date = try XCTUnwrap(attributes[.modificationDate] as? Date)
            try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(1)], ofItemAtPath: source.path)
        }
        XCTAssertEqual(try ReaderBase.scan(path, reader: reader, access: access).status, SourceStatus(ok: false, code: .busy))
        XCTAssertEqual(copies, ReaderBase.copyAttempts)
    }

    func testPrivateCopyRetriesAndRemovesStaleWAL() throws {
        let source = try database(in: folder(), wal: true)
        let destination = try folder().appendingPathComponent("snapshot")
        let writer = try SyntheticWriter(source)
        defer { writer.close() }
        try writer.execute("INSERT INTO records VALUES ('synthetic-WAL', 'Synthetic WAL body')")
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.copyItem(atPath: source.path + "-wal", toPath: destination.path + "-wal")
        var access = StoreAccess()
        let realCopy = access.copy
        var copies = 0
        access.copy = { source, target in
            try realCopy(source, target)
            copies += 1
            if source.path.hasSuffix("-wal") {
                try FileManager.default.removeItem(at: source)
            }
        }
        let result = try ReaderBase.scan(destination, reader: reader, access: access)
        XCTAssertEqual(result.status.count, 1)
        XCTAssertEqual(copies, 3, "database + WAL on first attempt, database on second")
    }

    func testGarbageFileIsUnreadable() throws {
        let path = try folder().appendingPathComponent("garbage")
        try Data(repeating: 0x61, count: 256).write(to: path)
        XCTAssertEqual(try ReaderBase.scan(path, reader: reader).status, SourceStatus(ok: false, code: .unreadable))
    }

    func testUnknownSchemaIsTypedAndNamesOnlySchema() throws {
        let path = try database(in: folder())
        for (table, needed, found) in [
            ("missing", ["body"], []),
            ("records", ["new_column"], ["guid", "body"]),
            ("missing", [], []),
        ] {
            XCTAssertThrowsError(try ReaderBase.scan(path, reader: { connection, _, _, _ in
                try connection.require(table, columns: needed)
            })) {
                XCTAssertEqual($0 as? UnknownSchemaError, UnknownSchemaError(table: table, found: found))
                XCTAssertFalse(String(describing: $0).contains("Synthetic body"))
            }
        }
        try ReaderBase.openReadOnly(path) { connection in
            XCTAssertEqual(try connection.columns("records"), ["guid", "body"])
            XCTAssertEqual(try connection.columns("missing"), [])
            // Quoted identifiers are escaped, rather than becoming a second statement.
            XCTAssertEqual(try connection.columns("records\"); DROP TABLE records; --"), [])
            XCTAssertEqual(try connection.require("records", columns: ["guid"]), ["guid", "body"])
        }
    }
}

extension ReaderBaseTests {
    func testSymlinkedWALStorePreservesSourceAndReadsItsLog() throws {
        let sourceFolder = try folder()
        let source = try database(in: sourceFolder, wal: true)
        let writer = try SyntheticWriter(source)
        defer { writer.close() }
        try writer.execute("INSERT INTO records VALUES ('synthetic-B', 'Only in the WAL')")
        let alias = try folder().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let before = try snapshot(sourceFolder)
        XCTAssertEqual(try ReaderBase.scan(alias, reader: reader).status.count, 2)
        XCTAssertEqual(try snapshot(sourceFolder), before)
    }

    func testPrivateCopyIsProtectedAndRemovedAfterSchemaFailure() throws {
        let path = try database(in: folder(), wal: true)
        var temporary: URL?
        var access = StoreAccess()
        let connect = access.connect
        access.connect = { uri, flags in
            let target = try XCTUnwrap(URL(string: uri))
            temporary = target.deletingLastPathComponent()
            let attributes = try FileManager.default.attributesOfItem(atPath: target.deletingLastPathComponent().path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: target.path)
            XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            return try connect(uri, flags)
        }
        XCTAssertThrowsError(try ReaderBase.scan(path, reader: { connection, _, _, _ in
            try connection.require("missing", columns: ["body"])
        }, access: access)) { XCTAssertTrue($0 is UnknownSchemaError) }
        let copiedFolder = try XCTUnwrap(temporary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedFolder.path))
    }

    func testCollectedAndStreamedItemsHaveSameCounts() throws {
        let path = try database(in: folder())
        let baseReader = reader
        let since = now.addingTimeInterval(-60)
        let mixedReader: ReaderBase.Reader = { connection, now, passedSince, emit in
            XCTAssertEqual(passedSince, since)
            try baseReader(connection, now, passedSince, emit)
            try emit(.problem(ReadProblem(code: "skip", source: "imessage", record: "synthetic-skipped", note: "missing time")))
        }
        let collected = try ReaderBase.scan(path, reader: mixedReader, now: now, since: since)
        var streamed: [ReadItem] = []
        let result = try ReaderBase.scan(path, reader: mixedReader, now: now, since: since, onItem: { streamed.append($0) })
        XCTAssertEqual(result.status, SourceStatus(ok: true, code: .ok, count: 1, problems: 1))
        XCTAssertEqual(result.status, collected.status)
        XCTAssertEqual(streamed, try [.event(XCTUnwrap(collected.events.first)), .problem(XCTUnwrap(collected.problems.first))])
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.problems.isEmpty)
        let onlyProblem = try ReaderBase.scan(path, reader: { _, _, _, emit in
            try emit(.problem(ReadProblem(code: "skip", source: "imessage", record: "synthetic-skipped")))
        })
        XCTAssertEqual(onlyProblem.status, SourceStatus(ok: true, code: .noData, problems: 1))
    }

    func testConnectionClosesAndCallbackErrorsPropagate() throws {
        enum CallbackError: Error { case stopped }
        let path = try database(in: folder())
        var retained: SQLiteConnection?
        XCTAssertThrowsError(try ReaderBase.openReadOnly(path) { connection in
            retained = connection
            try connection.query("SELECT * FROM records") { _ in throw CallbackError.stopped }
        }) { XCTAssertTrue($0 is CallbackError) }
        let closed = try XCTUnwrap(retained)
        XCTAssertThrowsError(try closed.query("SELECT * FROM records") { _ in }) {
            XCTAssertEqual(($0 as? SQLiteError)?.code, SQLITE_MISUSE)
        }
        XCTAssertThrowsError(try ReaderBase.scan(path, reader: reader, onItem: { _ in throw CallbackError.stopped })) {
            XCTAssertTrue($0 is CallbackError)
        }
        XCTAssertThrowsError(try ReaderBase.scan(path, reader: { connection, _, _, _ in
            try connection.query("SELECT missing_column FROM records") { _ in }
        })) { XCTAssertEqual(($0 as? SQLiteError)?.code, SQLITE_ERROR) }
    }

    func testExtendedStatusCodesAndPartialResults() throws {
        let path = try database(in: folder())
        for code in [SQLITE_BUSY | (1 << 8), SQLITE_LOCKED | (1 << 8)] {
            XCTAssertTrue(SQLiteError(code: code).isLocked)
            XCTAssertEqual(try ReaderBase.scan(path, reader: { _, _, _, _ in
                throw SQLiteError(code: code)
            }).status.code, .busy)
        }
        XCTAssertEqual(try ReaderBase.scan(path, reader: { _, _, _, _ in
            throw SQLiteError(code: SQLITE_CORRUPT)
        }).status.code, .unreadable)
        let baseReader = reader
        let partial = try ReaderBase.scan(path, reader: { connection, now, since, emit in
            try baseReader(connection, now, since, emit)
            throw SQLiteError(code: SQLITE_BUSY)
        })
        XCTAssertEqual(partial.status, SourceStatus(ok: false, code: .busy, count: 1))
        XCTAssertEqual(partial.events.count, 1)
    }

    func testStreamingTwentyThousandRowsKeepsMemoryFlat() throws {
        let path = try database(in: folder(), empty: true)
        let writer = try SyntheticWriter(path)
        try writer.execute("""
        WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 20000)
        INSERT INTO records SELECT 'synthetic-' || n, replace(hex(zeroblob(1024)), '0', 'x') FROM numbers
        """)
        writer.close()
        let warmReader: ReaderBase.Reader = { connection, now, _, emit in
            try connection.query("SELECT guid, body FROM records LIMIT 1000") { row in
                if case let .text(record) = row["guid"], case let .text(body) = row["body"] {
                    try emit(.event(ReaderBase.makeEvent(
                        source: .imessage, sourceRecordID: record, eventTime: now, eventTimeSource: .sent,
                        captureTime: now, body: body, content: .complete, route: .chatDB
                    )))
                }
            }
        }
        _ = try ReaderBase.scan(path, reader: warmReader, now: now, onItem: { _ in })
        let before = try peakMemoryBytes()
        var events = 0
        let result = try ReaderBase.scan(path, reader: reader, now: now, onItem: { item in
            if case .event = item {
                events += 1
            }
        })
        let growth = try peakMemoryBytes() - before
        XCTAssertEqual(events, 20000)
        XCTAssertEqual(result.status.count, 20000)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertLessThan(growth, 8 * 1024 * 1024, "streaming must not retain the roughly 40 MB of row bodies")
    }
}
