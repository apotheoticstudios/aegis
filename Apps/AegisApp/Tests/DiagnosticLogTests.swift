@testable import Aegis
import AegisKit
import Foundation
import XCTest

final class DiagnosticLogTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-diagnostic-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func rows(_ folder: URL) throws -> [DiagnosticLog.Record] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.flatMap { url in
                try Data(contentsOf: url).split(separator: 10).map { try decoder.decode(DiagnosticLog.Record.self, from: Data($0)) }
            }
    }

    func testPrivateSchemaAndPersistenceExcludeQuestionsAndArbitraryRefusalText() async throws {
        let folder = try folder()
        let log = DiagnosticLog(directory: folder)
        let service = DiagnosticCoreService(base: RefusingDiagnosticService(), log: log)
        _ = await service.handle(.ask(question: "Invented private body: example@example.com"))
        log.flush()
        let next = DiagnosticLog(directory: folder)
        next.record(.speechResultFailed, number: -1101)
        next.flush()
        let records = try rows(folder)
        XCTAssertTrue(records.contains { $0.code == .coreRefused })
        XCTAssertTrue(records.contains { $0.code == .speechResultFailed && $0.number == -1101 })
        let active = folder.appendingPathComponent("diagnostics.jsonl")
        let text = try String(contentsOf: active, encoding: .utf8)
        for forbidden in ["private body", "example@example.com", "invented arbitrary refusal"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: active.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int, 0o700)
        for line in try Data(contentsOf: active).split(separator: 10) {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            XCTAssertTrue(Set(object.keys).isSubset(of: [
                "schema",
                "code",
                "firstAt",
                "lastAt",
                "count",
                "number",
                "detail",
                "build",
                "pid",
            ]))
        }
    }

    func testConcurrentErrorsAreCountedAndRotationStaysBounded() throws {
        let folder = try folder()
        let log = DiagnosticLog(directory: folder, limit: 1024)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in log.record(.speechResultFailed, number: -1101) }
        log.flush()
        XCTAssertEqual(try rows(folder).filter { $0.code == .speechResultFailed }.reduce(0) { $0 + $1.count }, 200)
        for number in 0 ..< 30 {
            log.record(.microphoneFailed, number: number)
            log.flush()
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertLessThanOrEqual(files.count, 4)
        for file in files {
            XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max, 1024)
        }
        XCTAssertTrue(try rows(folder).contains { $0.code == .microphoneFailed && $0.number == 29 })
    }

    func testDisabledLoggingAndUnwritableDestinationDoNotAffectTheApp() throws {
        let folder = try folder()
        let disabled = DiagnosticLog(directory: folder.appendingPathComponent("disabled"), enabled: false)
        disabled.record(.microphoneFailed)
        disabled.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: disabled.directory.path))
        let occupied = folder.appendingPathComponent("occupied")
        try Data("Invented fixture".utf8).write(to: occupied)
        let log = DiagnosticLog(directory: occupied)
        log.record(.microphoneFailed)
        log.flush()
        XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "Invented fixture")
    }

    func testSymlinkDestinationDoesNotModifyAnotherFile() throws {
        let folder = try folder()
        let outside = folder.appendingPathComponent("outside.txt")
        try Data("Invented fixture".utf8).write(to: outside)
        let destination = folder.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("diagnostics.jsonl"), withDestinationURL: outside)
        let log = DiagnosticLog(directory: destination)
        log.record(.microphoneFailed)
        log.flush()
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "Invented fixture")
    }

    func testUncleanSessionIsRecordedAndCleanShutdownRemovesMarker() throws {
        let folder = try folder()
        try Data("99999999".utf8).write(to: folder.appendingPathComponent("session.pid"))
        let log = DiagnosticLog(directory: folder)
        log.startSession()
        log.stopSession()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.pid").path))
        let records = try rows(folder)
        XCTAssertTrue(records.contains { $0.code == .previousExitUnclean })
        XCTAssertTrue(records.contains { $0.code == .appStarted })
        XCTAssertTrue(records.contains { $0.code == .appStopped })
    }
}

private struct RefusingDiagnosticService: CoreService {
    func handle(_: CoreRequest) async -> CoreResponse {
        .refused(code: "invented arbitrary refusal")
    }
}
