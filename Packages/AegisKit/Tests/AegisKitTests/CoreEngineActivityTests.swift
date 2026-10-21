@testable import AegisKit
import Foundation
import XCTest

/// The panel's hourly counts (#8): every collected event counted once in its hour, by source, and nothing else.
final class CoreEngineActivityTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-activity-" + UUID().uuidString)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testCountsEachHourBySourceAcrossPages() async throws {
        let now = CommitmentFixture.date(10, hour: 18, minute: 30)
        let storage = MemoryStore()
        try await storage.ingest(CollectionBatch(
            source: .messages, status: .init(ok: true, code: .ok), events: [
                CommitmentFixture.event("old", "Too early", at: CommitmentFixture.date(10, hour: 15, minute: 59)),
                CommitmentFixture.event("first", "One", at: CommitmentFixture.date(10, hour: 16)),
                CommitmentFixture.event("second", "Two", at: CommitmentFixture.date(10, hour: 16, minute: 40)),
                CommitmentFixture.event("mail", "Three", at: CommitmentFixture.date(10, hour: 18, minute: 5), source: .email),
                CommitmentFixture.event("now", "Four", at: now, source: .notification),
            ], occurrences: [], reminders: [], checkpoint: nil
        ))
        let core = try CoreEngine(
            store: storage, collectors: [], model: RecordingModel(),
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: CommitmentFixture.calendar.timeZone),
            options: .init(modelName: "synthetic-model", pageSize: 2), calendar: CommitmentFixture.calendar, clock: { now }
        )
        guard case let .activity(activity) = await core.handle(.activity(hours: 3)) else {
            return XCTFail("expected activity")
        }
        XCTAssertEqual(activity.start, CommitmentFixture.date(10, hour: 16))
        XCTAssertEqual(activity.counts, [.imessage: [2, 0, 0], .email: [0, 0, 1], .notification: [0, 0, 1]])
        XCTAssertEqual(activity.total(hours: 3), [2, 0, 2])
        XCTAssertEqual(storage.savedCount, 0)
    }

    func testAsksForAtMostADay() async throws {
        let now = CommitmentFixture.date(10, hour: 18)
        let core = try CoreEngine(
            store: MemoryStore(), collectors: [], model: RecordingModel(),
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: CommitmentFixture.calendar.timeZone),
            options: .init(modelName: "synthetic-model"), calendar: CommitmentFixture.calendar, clock: { now }
        )
        guard case let .activity(activity) = await core.handle(.activity(hours: 500)) else {
            return XCTFail("expected activity")
        }
        XCTAssertEqual(activity.start, now.addingTimeInterval(-23 * 3600))
        XCTAssertTrue(activity.counts.isEmpty)
    }
}
