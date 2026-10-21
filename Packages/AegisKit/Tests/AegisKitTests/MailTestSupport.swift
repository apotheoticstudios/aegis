@testable import AegisKit
import Foundation
import XCTest

/// Synthetic stores only. Each test owns and removes its temporary store.
class MailTestCase: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_320_400)
    var root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aegis-mail-test-" + UUID().uuidString)

    var index: URL {
        root.appendingPathComponent("mail/V10/MailData/Envelope Index")
    }

    var version: URL {
        root.appendingPathComponent("mail/V10")
    }

    var messages: URL {
        version.appendingPathComponent("Synthetic.mbox/Data/0/1/Messages")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func generate(seed: Int = 7, profile: String = "full") throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("python3 is missing; synthetic Mail fixture parity requires the standard-library generator")
        }
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 {
            repository.deleteLastPathComponent()
        }
        let generator = Process()
        generator.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        generator.arguments = [
            "python3",
            repository.appendingPathComponent("Fixtures/generate/generate.py").path,
            root.path,
            "--seed",
            String(seed),
            "--profile",
            profile,
        ]
        generator.standardOutput = FileHandle.nullDevice
        try generator.run()
        generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0, "synthetic fixture generator failed")
    }

    func expectedEvents() throws -> [Event] {
        let data = try Data(contentsOf: root.appendingPathComponent("expected/mail.jsonl"))
        return try data.split(separator: 10).map { try JSONDecoder().decode(Event.self, from: Data($0)) }
    }

    func expectedProblems() throws -> [ReadProblem] {
        try JSONDecoder().decode([ReadProblem].self, from: Data(contentsOf: root.appendingPathComponent("expected/problems.json")))
            .filter { $0.source == "email" }
    }

    func modify(_ sql: String) throws {
        let writer = try SyntheticWriter(index)
        defer { writer.close() }
        try writer.execute(sql)
    }

    func build(deleted: Bool = true, flags: Bool = false, conversation: Bool = true) throws {
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        try modify("CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, date_received"
            + (deleted ? ", deleted INTEGER DEFAULT 0" : "")
            + (flags ? ", flags INTEGER DEFAULT 0" : "")
            + (conversation ? ", conversation_id INTEGER" : "") + ")")
    }

    func add(_ row: Int, received: Double? = nil, conversation: Bool = true) throws {
        try modify("INSERT INTO messages (ROWID, date_received" + (conversation ? ", conversation_id" : "")
            + ") VALUES (\(row), \(received.map { String($0) } ?? String(now.timeIntervalSince1970))"
            + (conversation ? ", 901" : "") + ")")
        try write(row)
    }

    @discardableResult
    func write(
        _ row: Int, overrides: [String: String] = [:], omitting: Set<String> = [], body: String = "Readable body",
        suffix: String = ".emlx", extra: [(String, String)] = []
    ) throws -> URL {
        let headers = [
            ("Message-ID", "<test-\(row)@example.com>"), ("From", "sender@example.com"),
            ("Subject", "Synthetic subject"), ("Date", "Tue, 06 Oct 2026 21:00:00 +0000"),
            ("Content-Type", "text/plain; charset=utf-8"),
        ].filter { !omitting.contains($0.0) }.map { ($0.0, overrides[$0.0] ?? $0.1) } + extra
        let raw = Data((headers.map { "\($0.0): \($0.1)" }.joined(separator: "\n") + "\n\n" + body).utf8)
        var data = Data("\(raw.count)\n".utf8)
        data.append(raw)
        let path = messages.appendingPathComponent(String(row) + suffix)
        try data.write(to: path)
        return path
    }

    func read(since: Date? = nil, access: MailAccess = MailAccess()) throws -> ReadResult {
        try MailReader.read(index, now: now, since: since, access: access)
    }

    func snapshot(_ folder: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        var files: [String: Data] = [:]
        for case let path as URL in enumerator {
            if try path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true, !path.path.hasSuffix("-shm") {
                files[path.path] = try Data(contentsOf: path)
            }
        }
        return files
    }
}
