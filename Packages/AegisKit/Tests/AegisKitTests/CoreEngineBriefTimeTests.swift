@testable import AegisKit
import Foundation
import XCTest

/// The setup wizard moves the daily brief (#26). Synthetic data only.
final class CoreEngineBriefTimeTests: XCTestCase {
    // 07:30 in Brisbane on 7 October (2026-10-06T21:30:00Z); the opening starts at 07:00.
    private let clock = TestClock(Date(timeIntervalSince1970: 1_791_322_200))
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-brief-time-" + UUID().uuidString)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func engine() throws -> CoreEngine {
        try CoreEngine(
            store: MemoryStore(),
            collectors: [],
            model: CitingModel(),
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: TimeZone(identifier: "Australia/Brisbane") ?? .gmt),
            options: .init(modelName: "synthetic-model"),
            clock: clock.read
        )
    }

    func testTheChosenTimeMovesTheNextBriefAndIsSaved() async throws {
        let core = try engine()
        guard case let .status(before) = await core.handle(.status) else { return XCTFail("expected status") }
        // 07:00 has passed today, so the next brief is tomorrow's.
        XCTAssertEqual(before.nextBriefAt, Date(timeIntervalSince1970: 1_791_322_200 + 23.5 * 3600))

        guard case let .status(after) = await core.handle(.setBriefTime(minutes: 8 * 60 + 15)) else {
            return XCTFail("expected status")
        }
        XCTAssertEqual(after.nextBriefAt, Date(timeIntervalSince1970: 1_791_322_200 + 45 * 60))

        // A restart keeps the owner's time, not the built-in 07:00.
        guard case let .status(restarted) = try await engine().handle(.status) else { return XCTFail("expected status") }
        XCTAssertEqual(restarted.nextBriefAt, after.nextBriefAt)
    }

    func testRefusesATimeOutsideTheDay() async throws {
        let core = try engine()
        for minutes in [-1, 24 * 60] {
            let reply = await core.handle(.setBriefTime(minutes: minutes))
            XCTAssertEqual(reply, .refused(code: "bad_time"))
        }
        let request = CoreRequest.setBriefTime(minutes: 390)
        XCTAssertEqual(try IPCCoding.decode(CoreRequest.self, from: IPCCoding.encode(request)), request)
    }
}

/// The setup wizard's tune-up (ADR-0030): one synthetic job, timed by the model.
final class CoreEngineTuneUpTests: XCTestCase {
    private struct TimedModel: ModelClient {
        let status: ModelJobResult.Status

        func run(_ job: ModelJob) async throws -> ModelJobResult {
            ModelJobResult(
                jobID: job.id, status: status, text: status == .completed ? "A beam sweeps the sea." : nil,
                failure: status == .completed ? nil : .modelMissing,
                metrics: ModelMetrics(loadSeconds: 3, generateSeconds: 8, generationTokens: 200)
            )
        }

        func cancel(jobID _: String) async {}
    }

    private func engine(_ status: ModelJobResult.Status) throws -> CoreEngine {
        try CoreEngine(
            store: MemoryStore(), collectors: [], model: TimedModel(status: status),
            persistence: ScheduleFile(url: FileManager.default.temporaryDirectory.appendingPathComponent("tune-\(UUID()).json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: .gmt),
            options: .init(modelName: "synthetic-model")
        )
    }

    func testReportsTheModelsTimings() async throws {
        let reply = try await engine(.completed).handle(.tuneUp)
        XCTAssertEqual(reply, .tuneUp(ModelMetrics(loadSeconds: 3, generateSeconds: 8, generationTokens: 200)))
        let failed = try await engine(.failed).handle(.tuneUp)
        XCTAssertEqual(failed, .refused(code: "model_missing"))
    }
}
