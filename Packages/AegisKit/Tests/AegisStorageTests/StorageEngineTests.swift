import AegisKit
@testable import AegisStorage
import Foundation
import XCTest

/// The engine against the real GRDB store: a brief published by one process is there after a restart.
@MainActor
final class StorageEngineTests: StorageTestCase {
    func testEnginePublishesIntoGRDBAndARestartRestoresIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-engine-db-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("aegis.sqlite").path
        let now = epoch.addingTimeInterval(3600)
        let events = [event(1, time: 600, body: "Synthetic message one"), event(2, time: 1200, body: "Synthetic message two")]
        func make(_ store: GRDBEventStore) throws -> CoreEngine {
            try CoreEngine(
                store: store,
                collectors: [FixedCollector(events: events)],
                model: FirstEventModel(),
                persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
                initial: BriefSchedule(openingHour: 0, openingMinute: 30, timeZone: XCTUnwrap(TimeZone(identifier: "UTC"))),
                options: .init(modelName: "synthetic-model"),
                clock: { now }
            )
        }
        let first = try make(GRDBEventStore(path: path))
        guard case .accepted = await first.handle(.refreshBrief(reason: .user)) else {
            return XCTFail("expected accepted")
        }
        await first.settle()
        let published = await first.handle(.latestBrief)
        guard case let .brief(stored?) = published else {
            return XCTFail("expected a published brief, got \(published)")
        }
        XCTAssertTrue(events.map(\.id).contains(stored.brief.items.first?.eventIDs.first ?? ""))

        // A new process opens the same database and schedule file.
        let second = try make(GRDBEventStore(path: path))
        await second.start()
        let restored = await second.handle(.latestBrief)
        XCTAssertEqual(restored, published)
    }
}

extension StorageEngineTests {
    func testEventsByIDReturnsOnlyStoredOnes() async throws {
        let store = try open()
        let events = [event(1, time: 600), event(2, time: 1200), event(3, time: 1800)]
        try await store.ingest(batch(events))
        let found = try await store.events(ids: [events[2].id, "ev_ffffffffffffffff", events[0].id, events[0].id])
        XCTAssertEqual(Set(found.map(\.id)), [events[0].id, events[2].id])
        let none = try await store.events(ids: [])
        XCTAssertEqual(none, [])
    }
}

private struct FixedCollector: EventCollector {
    let events: [Event]
    var source: SourceKind {
        .messages
    }

    func collect(after _: CollectionCheckpoint?, now: Date) async throws -> CollectionBatch {
        CollectionBatch(
            source: .messages,
            status: SourceStatus(ok: true, code: .ok, count: events.count),
            events: events,
            checkpoint: CollectionCheckpoint(source: .messages, cursor: "synthetic", scannedAt: now, complete: true)
        )
    }
}

private struct FirstEventModel: ModelClient {
    func run(_ job: ModelJob) async throws -> ModelJobResult {
        let id = job.user.range(of: #"ev_[0-9a-f]{16}"#, options: .regularExpression).map { String(job.user[$0]) } ?? ""
        let answer = #"{"items": [{"text": "Synthetic summary.", "priority": "fyi", "event_ids": [""# + id + #""]}]}"#
        return ModelJobResult(jobID: job.id, status: .completed, text: answer)
    }

    func cancel(jobID _: String) async {}
}
