@testable import AegisKit
import Foundation
import XCTest

final class MailReaderEdgeTests: MailTestCase {
    func testMissingAndDuplicateIDsAndTimeProblems() throws {
        try build()
        for row in 1 ... 7 {
            try add(row)
        }
        try write(1, omitting: ["Message-ID"])
        try write(2, overrides: ["Message-ID": ""])
        try write(4, overrides: ["Message-ID": "<test-3@example.com>"])
        try write(5, omitting: ["Date"])
        try write(6, overrides: ["Date": "Fri, 01 Jan 1999 00:00:00 +0000"])
        try write(7, overrides: ["Date": "Fri, 01 Jan 2100 00:00:00 +0000"])
        try modify("UPDATE messages SET date_received = NULL WHERE ROWID = 5")
        let result = try read()
        XCTAssertEqual(result.events.map(\.sourceRecordID), ["<test-3@example.com>"])
        XCTAssertEqual(result.problems, [
            ReadProblem(code: "missing_message_id", source: "email", record: "1"),
            ReadProblem(code: "missing_message_id", source: "email", record: "2"),
            ReadProblem(code: "duplicate_message_id", source: "email", record: "4", note: "<test-3@example.com>"),
            ReadProblem(code: "missing_timestamp", source: "email", record: "5"),
            ReadProblem(code: "timestamp_out_of_range", source: "email", record: "6"),
            ReadProblem(code: "timestamp_out_of_range", source: "email", record: "7"),
        ])
    }

    func testInvalidIndexDatesAndPlausibleBoundary() throws {
        try build()
        for row in 1 ... 6 {
            try add(row); try write(row, omitting: ["Date"])
        }
        try modify("UPDATE messages SET date_received = CASE ROWID WHEN 1 THEN 0 WHEN 2 THEN 'bad'"
            + " WHEN 3 THEN '1e999' WHEN 4 THEN 978307200 WHEN 5 THEN 1791320400 ELSE 1e100 END")
        let result = try read()
        XCTAssertEqual(result.problems.map(\.code), Array(repeating: "missing_timestamp", count: 4))
        XCTAssertEqual(result.events.first?.eventTime, Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(result.events.last?.eventTime, now)
    }

    func testDuplicateOutsideWindowDoesNotSuppressSelectedMessage() throws {
        try build()
        try add(1)
        try add(2)
        try write(1, overrides: ["Date": "Tue, 06 Oct 2026 17:00:00 +0000"])
        try write(2, overrides: ["Message-ID": "<test-1@example.com>"])
        let result = try read(since: now.addingTimeInterval(-3600))
        XCTAssertEqual(result.events.map(\.sourceRecordID), ["<test-1@example.com>"])
        XCTAssertTrue(result.problems.isEmpty)
    }

    func testVanishingFileAndParserErrorDoNotStopRead() throws {
        enum ParseFailure: Error { case invalid }
        try build()
        for row in 1 ... 3 {
            try add(row)
        }
        var access = MailAccess()
        let load = access.readFile, parse = access.parse
        access.readFile = { path in
            if path.lastPathComponent == "1.emlx" {
                try FileManager.default.removeItem(at: path)
            }
            return try load(path)
        }
        access.parse = { data, partial, date in
            if String(data: data, encoding: .utf8)?.contains("<test-2@example.com>") == true {
                throw ParseFailure.invalid
            }
            return try parse(data, partial, date)
        }
        let result = try read(access: access)
        XCTAssertEqual(result.events.map(\.sourceRecordID), ["<test-3@example.com>"])
        XCTAssertEqual(result.problems, [
            ReadProblem(code: "body_file_missing", source: "email", record: "1"),
            ReadProblem(code: "message_parse_error", source: "email", record: "2"),
        ])
    }

    func testPartialEncryptedAttachmentOnlyAndCompletePreference() throws {
        try build()
        for row in 1 ... 6 {
            try add(row)
        }
        for row in 1 ... 5 {
            try FileManager.default.removeItem(at: messages.appendingPathComponent("\(row).emlx"))
        }
        try write(1, overrides: ["Content-Type": "application/pkcs7-mime"], body: "ciphertext", suffix: ".partial.emlx")
        try write(2, overrides: ["Content-Type": "image/jpeg"], body: "attachment", suffix: ".partial.emlx")
        try write(3, body: "", suffix: ".partial.emlx")
        try write(4, suffix: ".partial.emlx")
        try write(5, suffix: ".emlxpart")
        let partial = try write(6, body: "Partial body", suffix: ".partial.emlx")
        let complete = messages.appendingPathComponent("6.emlx")
        for order in [[partial, complete], [complete, partial]] {
            var access = MailAccess()
            let list = access.listFiles
            access.listFiles = { folder, visit in
                try list(folder) {
                    if ![partial, complete].contains($0) {
                        try visit($0)
                    }
                }
                for path in order {
                    try visit(path)
                }
            }
            let result = try read(access: access)
            XCTAssertEqual(result.events.map(\.content), [.unavailable, .unavailable, .unavailable, .preview, .preview, .complete])
            XCTAssertEqual(result.events.map(\.flags), [
                [.encrypted, .truncated], [.attachmentOnly, .truncated], [.truncated], [.truncated], [.truncated], [],
            ])
            XCTAssertEqual(result.events.map(\.body), ["", "", "", "Readable body", "Readable body", "Readable body"])
        }
    }

    func testMalformedHeadersAndAbsentVersusEmpty() throws {
        try build()
        for row in 1 ... 7 {
            try add(row)
        }
        try modify("UPDATE messages SET conversation_id = NULL")
        try write(1, overrides: ["Date": "sometime last week"])
        try write(2, overrides: ["From": "<"])
        try write(3, overrides: ["Message-ID": "<@"])
        try write(4, overrides: ["From": "J. Sample <jordan@example.com>"])
        try write(5, overrides: ["Message-ID": "1234.5678@mail.example.com"])
        try write(6, omitting: ["From", "Subject"])
        try write(7, overrides: ["From": "", "Subject": ""])
        let result = try read()
        XCTAssertEqual(result.events.count, 7)
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertEqual(result.events[0].eventTimeSource, .received)
        XCTAssertEqual(result.events[0].eventTime, now)
        XCTAssertEqual(result.events[2].sourceRecordID, "<@")
        XCTAssertEqual(result.events[3].senderHandle, "jordan@example.com")
        XCTAssertEqual(result.events[4].sourceRecordID, "1234.5678@mail.example.com")
        XCTAssertNil(result.events[5].sender)
        XCTAssertNil(result.events[5].title)
        XCTAssertEqual(result.events[6].sender, "")
        XCTAssertEqual(result.events[6].title, "")
        XCTAssertNil(result.events[6].senderHandle)
        XCTAssertTrue(result.events.allSatisfy { $0.threadID == nil && $0.direction == .incoming && $0.recipients.isEmpty })
    }

    func testFutureFlagAndHTMLHeaderDefects() throws {
        try build()
        try add(1)
        try add(2)
        try write(1, overrides: ["Date": "Wed, 06 Oct 2027 21:00:00 +0000"])
        try write(
            2,
            overrides: ["Content-Type": "text/html"],
            body:
            "<HEAD><title>Wrong title</title><style>.a{color:red}</style>"
                + "<body><script>var x=1;</script><p>Hello &amp; welcome</p><p> Next line. </p></body>"
        )
        let result = try read()
        XCTAssertEqual(result.events[0].flags, [.clockSkew])
        XCTAssertEqual(result.events[1].body, "Hello & welcome Next line.")
    }

    func testNestedNumericDirectoriesAndSymlinks() throws {
        try build()
        try add(1)
        let original = messages.appendingPathComponent("1.emlx")
        let nested = messages.deletingLastPathComponent().appendingPathComponent("2/3/Messages")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: nested.appendingPathComponent("1.emlx"))
        XCTAssertEqual(try read().status.count, 1)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: nested.appendingPathComponent("1.emlx"))
        try modify("INSERT INTO messages (ROWID, date_received) VALUES (2, 1791320400)")
        try FileManager.default.createSymbolicLink(
            at: messages.appendingPathComponent("2.emlx"),
            withDestinationURL: nested.appendingPathComponent("1.emlx")
        )
        XCTAssertEqual(try read().problems, [ReadProblem(code: "body_file_missing", source: "email", record: "2")])
    }

    func testStatusesSchemaAndCallbackFailures() throws {
        XCTAssertEqual(try read().status.code, .notFound)
        try build()
        try add(1)
        var access = MailAccess()
        access.readFile = { _ in throw StoreUnavailable(code: .permissionDenied) }
        XCTAssertEqual(try read(access: access).status, SourceStatus(ok: false, code: .permissionDenied))
        access = MailAccess()
        access.listFiles = { _, _ in throw StoreUnavailable(code: .permissionDenied) }
        XCTAssertEqual(try read(access: access).status.code, .permissionDenied)
        enum CallbackError: Error { case stopped }
        XCTAssertThrowsError(try MailReader.read(index, now: now, onItem: { _ in throw CallbackError.stopped })) {
            XCTAssertTrue($0 is CallbackError)
        }
        try modify("DROP TABLE messages")
        XCTAssertEqual(try read().status, SourceStatus(ok: false, code: .formatChanged))
        try FileManager.default.removeItem(at: index)
        try Data(repeating: 0x61, count: 256).write(to: index)
        XCTAssertEqual(try read().status.code, .unreadable)
    }
}
