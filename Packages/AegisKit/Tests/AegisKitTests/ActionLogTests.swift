@testable import AegisKit
import Foundation
import XCTest

final class ActionLogTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-action-tests-" + UUID().uuidString)
    private var url: URL {
        folder.appendingPathComponent("actions.jsonl")
    }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testEmptyLogAppendOrderAndRestart() throws {
        let file = try ActionLogFile(url: url, maxEntries: 3)
        XCTAssertEqual(try file.load(), [])
        // Append order is authoritative even when clocks move backwards.
        let entries = [entry(3), entry(2), entry(1)]
        for entry in entries {
            try file.append(entry)
        }
        XCTAssertEqual(try file.load(), entries)
        XCTAssertEqual(try ActionLogFile(url: url, maxEntries: 3).load(), entries)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.archiveURL.path))
        XCTAssertEqual(try lines(url).count, 3)
    }

    func testRotationKeepsOneArchiveAndReturnsNewestBoundedEntries() throws {
        let file = try ActionLogFile(url: url, maxEntries: 3)
        let entries = (1 ... 10).map(entry)
        for (index, entry) in entries.enumerated() {
            try file.append(entry)
            XCTAssertEqual(try file.load(), Array(entries.prefix(index + 1).suffix(3)))
            XCTAssertLessThanOrEqual(try lines(url).count, 3)
            if FileManager.default.fileExists(atPath: file.archiveURL.path) {
                XCTAssertLessThanOrEqual(try lines(file.archiveURL).count, 3)
            }
        }
        XCTAssertEqual(try decodedLines(file.archiveURL), Array(entries[6 ... 8]))
        XCTAssertEqual(try decodedLines(url), [entries[9]])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["actions.jsonl", "actions.jsonl.1"])
        XCTAssertEqual(try ActionLogFile(url: url, maxEntries: 3).load(), Array(entries.suffix(3)))
    }

    func testCapacityOneRotatesOnEveryFurtherAppend() throws {
        let file = try ActionLogFile(url: url, maxEntries: 1)
        let entries = (1 ... 3).map(entry)
        for entry in entries {
            try file.append(entry)
        }
        XCTAssertEqual(try file.load(), [entries[2]])
        XCTAssertEqual(try decodedLines(file.archiveURL), [entries[1]])
        XCTAssertEqual(try decodedLines(url), [entries[2]])
    }

    func testInterruptedRotationRecoversWithoutDuplicatingOrLosingEntries() throws {
        let file = try ActionLogFile(url: url, maxEntries: 3)
        let entries = (1 ... 4).map(entry)
        for entry in entries.prefix(3) {
            try file.append(entry)
        }
        // Simulate interruption after archive replacement, before active replacement.
        try Data(contentsOf: url).write(to: file.archiveURL, options: .atomic)
        XCTAssertEqual(try file.load(), Array(entries.prefix(3)))
        try file.append(entries[3])
        XCTAssertEqual(try file.load(), Array(entries.suffix(3)))
        XCTAssertEqual(try decodedLines(url), [entries[3]])
    }

    func testFailedRotationPreservesTheActiveGenerationAndCanBeRetried() throws {
        let file = try ActionLogFile(url: url, maxEntries: 2)
        let entries = (1 ... 3).map(entry)
        for entry in entries.prefix(2) {
            try file.append(entry)
        }
        let before = try Data(contentsOf: url)
        try FileManager.default.createDirectory(at: file.archiveURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try file.append(entries[2])) { error in
            XCTAssertEqual(error as? ActionLogError, .persistenceFailure)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        try FileManager.default.removeItem(at: file.archiveURL)
        try file.append(entries[2])
        XCTAssertEqual(try file.load(), Array(entries.suffix(2)))
    }

    func testPayloadTextNeverReachesActiveOrArchivedLog() throws {
        let file = try ActionLogFile(url: url, maxEntries: 2)
        let time = Date(timeIntervalSince1970: 1000)
        let marker = "SYNTHETIC_PRIVATE_PAYLOAD"
        let payloads: [ActionPayload] = [
            .message(recipientHandle: marker, text: marker),
            .home(accessory: marker, characteristic: .light, value: .text(marker)),
            .app(bundleID: marker, verb: .open), .file(path: marker, verb: .open),
            .calendar(title: marker, start: time, end: time), .reminder(title: marker, due: time),
            .system(setting: .appearance, value: .text(marker)),
        ]
        for payload in payloads {
            let request = ActionRequest(payload: payload, origin: .ownerTyped)
            let decision = ActionPolicy.decision(for: request, settings: .init(panelIsOpen: true))
            let entry = ActionLogEntry(time: time, request: request, decision: decision, outcomeCode: .proposed)
            try file.append(entry)
            XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(marker))
            if FileManager.default.fileExists(atPath: file.archiveURL.path) {
                XCTAssertFalse(try String(contentsOf: file.archiveURL, encoding: .utf8).contains(marker))
            }
        }
        for data in try lines(url) + lines(file.archiveURL) {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["time", "requestID", "domain", "decision", "outcomeCode"])
            XCTAssertNotNil(try UUID(uuidString: XCTUnwrap(object["requestID"] as? String)))
        }
    }

    func testInvalidBoundsAndNonFileLocationAreRejected() {
        for limit in [0, -1, Int.max] {
            XCTAssertThrowsError(try ActionLogFile(url: url, maxEntries: limit)) { error in
                XCTAssertEqual(error as? ActionLogError, .invalidLimit)
            }
        }
        XCTAssertThrowsError(try ActionLogFile(url: URL(string: "https://example.invalid/actions") ?? url)) { error in
            XCTAssertEqual(error as? ActionLogError, .invalidLocation)
        }
    }

    func testCorruptOrOversizedFilesAreRejectedWithoutAppending() throws {
        let file = try ActionLogFile(url: url, maxEntries: 1)
        for data in [Data("not-json\n".utf8), Data("{}".utf8), Data("\n".utf8), Data(repeating: 32, count: 4097)] {
            try data.write(to: url, options: .atomic)
            XCTAssertThrowsError(try file.load()) { error in
                XCTAssertEqual(error as? ActionLogError, .corruptLog)
            }
            XCTAssertThrowsError(try file.append(entry(1)))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    @MainActor
    func testActorSerializesConcurrentAppendsThroughPersistenceContract() async throws {
        let file = try ActionLogFile(url: url, maxEntries: 30)
        let log = ActionLog(persistence: file)
        let expected = (1 ... 20).map(entry)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for entry in expected {
                group.addTask { try await log.append(entry) }
            }
            try await group.waitForAll()
        }
        let actual = try await log.entries()
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertEqual(Set(actual), Set(expected))
        XCTAssertEqual(try ActionLogFile(url: url, maxEntries: 30).load(), actual)
    }

    private func entry(_ index: Int) -> ActionLogEntry {
        ActionLogEntry(
            time: Date(timeIntervalSince1970: Double(index)), requestID: UUID(), domain: .app,
            decision: .init(tier: .auto, reasonCodes: [.reversible]), outcomeCode: .proposed
        )
    }

    private func lines(_ location: URL) throws -> [Data] {
        try Data(contentsOf: location).split(separator: 10).map { Data($0) }
    }

    private func decodedLines(_ location: URL) throws -> [ActionLogEntry] {
        try lines(location).map { try JSONDecoder().decode(ActionLogEntry.self, from: $0) }
    }
}
