@testable import AegisKit
import Foundation
import XCTest

final class MailReaderTests: MailTestCase {
    func testFixtureParitySeed7() throws {
        try checkParity(seed: 7)
    }

    func testFixtureParitySeed42() throws {
        try checkParity(seed: 42)
    }

    func testEmptyFixture() throws {
        try checkParity(profile: "empty")
    }

    func testDriftFixtureWithoutConversation() throws {
        try generate(profile: "drift")
        for path in [index, version, root.appendingPathComponent("mail")] {
            var emitted = 0
            let result = try MailReader.read(path, now: now, onItem: { _ in emitted += 1 })
            XCTAssertEqual(result.status, SourceStatus(ok: false, code: .formatChanged))
            XCTAssertTrue(result.events.isEmpty)
            XCTAssertEqual(emitted, 0)
        }
    }

    private func checkParity(seed: Int = 7, profile: String = "full") throws {
        try generate(seed: seed, profile: profile)
        let before = try snapshot(root.appendingPathComponent("mail"))
        let expected = try expectedEvents()
        let problems = try expectedProblems()
        for path in [index, version, root.appendingPathComponent("mail")] {
            let result = try MailReader.read(path, now: now)
            XCTAssertEqual(result.events, expected)
            XCTAssertEqual(result.problems, problems)
            XCTAssertEqual(result.status, SourceStatus(
                ok: true,
                code: expected.isEmpty ? .noData : .ok,
                count: expected.count,
                problems: problems.count
            ))
            for event in result.events {
                XCTAssertTrue(event.validate().isEmpty)
            }
        }
        XCTAssertEqual(try snapshot(root.appendingPathComponent("mail")), before)
    }

    func testFixtureStreamingAndWindow() throws {
        try generate()
        var events: [Event] = [], problems: [ReadProblem] = []
        let result = try MailReader.read(index, now: now, onItem: { item in
            switch item {
            case let .event(event): events.append(event)
            case let .problem(problem): problems.append(problem)
            }
        })
        XCTAssertEqual(events, try expectedEvents())
        XCTAssertEqual(problems, try expectedProblems())
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertEqual(result.status.count, events.count)
        XCTAssertEqual(result.status.problems, problems.count)
        let cutoff = now.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(try read(since: cutoff).events, try expectedEvents().filter { $0.eventTime >= cutoff })
    }

    func testDeletedColumnAndFlagsBit() throws {
        for (deleted, flags) in [(true, false), (false, true), (false, false)] {
            try build(deleted: deleted, flags: flags)
            for row in 1 ... 3 {
                try add(row)
            }
            if deleted {
                try modify("UPDATE messages SET deleted = CASE ROWID WHEN 1 THEN 1 WHEN 2 THEN NULL ELSE 2 END")
            } else if flags {
                try modify("UPDATE messages SET flags = CASE ROWID WHEN 1 THEN 2 WHEN 2 THEN NULL ELSE 1 END")
            }
            XCTAssertEqual(
                try read().events.map(\.sourceRecordID),
                (deleted || flags ? [2, 3] : [1, 2, 3])
                    .map { "<test-\($0)@example.com>" }
            )
            try FileManager.default.removeItem(at: index)
        }
    }

    func testUnixAndCocoaEpochAndIndexFallback() throws {
        try build()
        for row in 1 ... 3 {
            try add(row)
        }
        try write(1, omitting: ["Date"])
        try write(2, overrides: ["Date": "broken"], extra: [
            ("Received", "from mx; Tue, 06 Oct 2026 20:00:00 +0000"),
            ("Received", "from older; Tue, 06 Oct 2026 19:00:00 +0000"),
        ])
        let unix = try read()
        XCTAssertEqual(unix.events.map(\.eventTimeSource), [.received, .received, .header])
        XCTAssertEqual(unix.events[0].eventTime, now)
        XCTAssertEqual(unix.events[1].eventTime, now.addingTimeInterval(-3600))
        try modify("UPDATE messages SET date_received = date_received - 978307200")
        XCTAssertEqual(try read().events, unix.events)
        XCTAssertEqual(try read(since: now.addingTimeInterval(-1800)).events, [unix.events[0], unix.events[2]])
    }

    func testSQLWindowSlackBeforeOpeningFiles() throws {
        try build()
        let cutoff = now.addingTimeInterval(-3 * 3600)
        try add(1, received: cutoff.timeIntervalSince1970 - 86401)
        try add(2, received: cutoff.timeIntervalSince1970 - 86400)
        try add(3)
        try add(4, received: cutoff.timeIntervalSince1970 - 172_800)
        try add(5)
        try write(5, overrides: ["Date": "Tue, 06 Oct 2026 17:59:59 +0000"])
        try modify("UPDATE messages SET deleted = 1 WHERE ROWID = 3")
        try FileManager.default.removeItem(at: messages.appendingPathComponent("4.emlx"))
        var access = MailAccess(), walks = 0, opened: [String] = []
        let list = access.listFiles, load = access.readFile
        access.listFiles = { folder, visit in walks += 1; try list(folder, visit) }
        access.readFile = { path in opened.append(path.lastPathComponent); return try load(path) }
        let result = try read(since: cutoff, access: access)
        XCTAssertEqual(walks, 1)
        XCTAssertEqual(opened, ["2.emlx", "5.emlx"])
        XCTAssertEqual(result.events.map(\.sourceRecordID), ["<test-2@example.com>"])
        XCTAssertTrue(result.problems.isEmpty)
    }

    func testDeletedRowsAndEmptyWindowSkipWalk() throws {
        try build()
        try add(1)
        var access = MailAccess()
        access.listFiles = { _, _ in XCTFail("empty selection must not walk") }
        access.readFile = { _ in XCTFail("empty selection must not open"); return Data() }
        XCTAssertEqual(try read(since: now.addingTimeInterval(3 * 86400), access: access).status.code, .noData)
        try modify("UPDATE messages SET deleted = 1")
        XCTAssertEqual(try read(access: access).status, SourceStatus(ok: true, code: .noData))
    }

    func testFiveThousandMessagesOneWalkAndWindow() throws {
        try build()
        for row in 1 ... 5000 {
            try add(row, received: now.timeIntervalSince1970 - Double(row) * 60)
            try write(row, overrides: ["Date": "broken"])
        }
        var access = MailAccess(), walks = 0, opens = 0, count = 0
        let list = access.listFiles, load = access.readFile
        access.listFiles = { folder, visit in walks += 1; try list(folder, visit) }
        access.readFile = { path in opens += 1; return try load(path) }
        let result = try MailReader.read(
            index,
            now: now,
            since: now.addingTimeInterval(-86400),
            onItem: {
                if case .event = $0 {
                    count += 1
                }
            },
            access: access
        )
        XCTAssertEqual(walks, 1)
        XCTAssertEqual(opens, 2880, "only the one-day window plus one day of slack is opened")
        XCTAssertEqual(count, 1440)
        XCTAssertEqual(result.status, SourceStatus(ok: true, code: .ok, count: 1440))
        XCTAssertTrue(result.events.isEmpty)
    }
}
