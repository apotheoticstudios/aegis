import AegisKit
import CSQLite
import Foundation
import XCTest

final class ReaderHelpersTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSQLiteCellsAndBindings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-synthetic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("empty")
        try Data().write(to: path)
        let values: [SQLiteValue] = [
            .null,
            .integer(Int64.max),
            .real(1.25),
            .text("synthetic\0text"),
            .blob(Data([0, 1, 255])),
            .blob(Data()),
            .text(""),
        ]
        try ReaderBase.openReadOnly(path) { connection in
            try connection.query("SELECT ?, ?, ?, ?, ?, ?, ?", bindings: values) { row in
                XCTAssertEqual(row.values, values)
                XCTAssertNil(row["missing"])
            }
            XCTAssertThrowsError(try connection.query("SELECT ?") { _ in }) {
                XCTAssertEqual(($0 as? SQLiteError)?.code, SQLITE_RANGE)
            }
        }
    }

    func testHelpersMatchStageZero() throws {
        XCTAssertEqual(ReaderBase.cocoa(0), Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(try ReaderBase.cocoaSeconds(XCTUnwrap(ReaderBase.cocoa(1.25))), 1.25)
        for seconds in [-1.0, 3_124_137_600, .infinity, -.infinity, .nan] {
            XCTAssertNil(ReaderBase.cocoa(seconds))
        }
        XCTAssertNotNil(ReaderBase.cocoa(3_124_137_599))
        XCTAssertEqual(ReaderBase.number(.integer(12)), 12)
        XCTAssertEqual(ReaderBase.number(.real(1.5)), 1.5)
        for value in [nil, SQLiteValue.null, .text("12"), .blob(Data())] {
            XCTAssertNil(ReaderBase.number(value))
        }
        XCTAssertEqual(ReaderBase.skewFlags(now.addingTimeInterval(600), now: now), [])
        XCTAssertEqual(ReaderBase.skewFlags(now.addingTimeInterval(600.001), now: now), [.clockSkew])
        let event = ReaderBase.makeEvent(
            source: .email, sourceRecordID: "synthetic-mail-id", eventTime: now.addingTimeInterval(0.75),
            eventTimeSource: .received, captureTime: now, body: "Synthetic email body", content: .preview, route: .mailStore,
            appID: "synthetic.mail", sender: "synthetic-sender", threadID: "synthetic-thread", title: "Synthetic title",
            flags: [.truncated]
        )
        XCTAssertEqual(event.id, EventID.make(source: .email, sourceRecordID: "synthetic-mail-id"))
        XCTAssertEqual(event.eventTime, now)
        XCTAssertEqual(event.observations, [.init(route: .mailStore, sourceRecordID: "synthetic-mail-id", captureTime: now)])
        XCTAssertEqual(event.flags, [.truncated])
        XCTAssertTrue(event.validate().isEmpty)
        let encoded = try JSONEncoder().encode(ReadProblem(code: "skip", source: "email", record: "synthetic-id"))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        XCTAssertEqual(fields, ["code": "skip", "source": "email", "record": "synthetic-id", "note": ""])
    }
}
