@testable import AegisKit
import Foundation
import XCTest

/// Builds only synthetic stores, using the same Python generator as the Stage 0 specification.
struct SwiftReaderFixtures {
    let root: URL
    let now = Date(timeIntervalSince1970: 1_791_320_400) // 2026-10-06T21:00:00Z
    var notifications: URL {
        root.appendingPathComponent("notifications/db")
    }

    var messages: URL {
        root.appendingPathComponent("messages/chat.db")
    }

    init(_ test: XCTestCase, seed: Int = 7, profile: String = "full") throws {
        root = try test.syntheticReaderFolder()
        try Self.python([
            Self.repository.appendingPathComponent("Fixtures/generate/generate.py").path,
            root.path, "--seed", String(seed), "--profile", profile,
        ])
    }

    static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func python(_ arguments: [String]) throws {
        let environment = ProcessInfo.processInfo.environment
        let candidates = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("python3")
        }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("python3 is unavailable; synthetic fixture parity requires the repo's Python generator")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Counts and diagnostics from the synthetic generator only.
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let diagnostics = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SyntheticFixtureGenerator", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: String(data: diagnostics, encoding: .utf8) ?? "Fixture generator failed",
            ])
        }
    }

    func expected(_ name: String) throws -> [Event] {
        let data = try Data(contentsOf: root.appendingPathComponent("expected/\(name).jsonl"))
        return try data.split(separator: 10).map { try JSONDecoder().decode(Event.self, from: Data($0)) }
    }

    func expectedProblems(_ sources: Set<String>) throws -> [ReadProblem] {
        try JSONDecoder().decode([ReadProblem].self, from: Data(contentsOf: root.appendingPathComponent("expected/problems.json")))
            .filter { sources.contains($0.source) }
    }
}

extension XCTestCase {
    func syntheticReaderFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-swift-readers-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }

    func readerCopy(_ source: URL) throws -> URL {
        let path = try syntheticReaderFolder().appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: path)
        return path
    }

    func readerSnapshot(_ path: URL) throws -> [String: Data] {
        let folder = path.deletingLastPathComponent()
        return try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: folder.path).map {
            try ($0, Data(contentsOf: folder.appendingPathComponent($0)))
        })
    }

    func assertReaderEvents(_ got: [Event], _ want: [Event], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, Set(got.map(\.id)).count, "duplicate event IDs", file: file, line: line)
        XCTAssertEqual(got.sorted { $0.id < $1.id }, want.sorted { $0.id < $1.id }, file: file, line: line)
        for (event, expected) in zip(got.sorted { $0.id < $1.id }, want.sorted { $0.id < $1.id }) {
            XCTAssertEqual(event.validate(), [], file: file, line: line)
            XCTAssertEqual(Array(event.body.utf8), Array(expected.body.utf8), file: file, line: line)
            XCTAssertEqual(event.title.map { Array($0.utf8) }, expected.title.map { Array($0.utf8) }, file: file, line: line)
        }
    }

    /// Generator notes explain fixtures; the Python readers compare the stable code/source/record fields.
    func assertReaderProblems(_ got: [ReadProblem], _ want: [ReadProblem], file: StaticString = #filePath, line: UInt = #line) {
        func keys(_ problems: [ReadProblem]) -> [String] {
            problems.map { [$0.code, $0.source, $0.record].joined(separator: "\u{1F}") }.sorted()
        }
        XCTAssertEqual(keys(got), keys(want), file: file, line: line)
    }
}
