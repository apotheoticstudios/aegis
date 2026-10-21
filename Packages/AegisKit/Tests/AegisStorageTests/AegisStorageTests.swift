import AegisKit
@testable import AegisStorage
import Foundation
import GRDB
import XCTest

@MainActor
final class AegisStorageTests: StorageTestCase {
    func testAtomicFailureRollsBackRecordsIndexAndCheckpoint() async throws {
        let store = try open(failure: {
            if $0 == 1 {
                throw CancellationError()
            }
        })
        let original = batch([event(0)])
        try await store.ingest(original)
        do {
            try await store.ingest(batch([event(1, body: "RollbackToken"), event(2)], scan: 1))
            XCTFail("expected injected failure")
        } catch is CancellationError {}
        let events = try await allEvents(store)
        let checkpoint = try await store.checkpoint(for: .messages)
        let matches = try await store.events(matching: "RollbackToken")
        XCTAssertEqual(events.map(\.id), [event(0).id])
        XCTAssertEqual(checkpoint, original.checkpoint)
        XCTAssertTrue(matches.isEmpty)
        // A separate connection after reopening sees only committed state.
        let reopened = try open()
        let persisted = try await allEvents(reopened)
        XCTAssertEqual(persisted, events)
    }

    func testReplaysEditsAndObservationIdentity() async throws {
        let store = try open()
        let original = batch([event(0)])
        try await store.ingest(original)
        let initialJSON = try await store.queue.read { db in try Data.fetchOne(db, sql: "SELECT json FROM event") }
        try await store.ingest(original)
        let json = try await store.queue.read { db in try Data.fetchOne(db, sql: "SELECT json FROM event") }
        // Replays leave JSON and row identity unchanged.
        let first = try await allEvents(store)
        XCTAssertEqual(first, original.events)
        XCTAssertEqual(json, initialJSON)
        var edited = event(0, capture: 10, body: "Edited text")
        edited.observations += [.init(route: .notificationDB, sourceRecordID: "synthetic-notification", captureTime: epoch)]
        edited.observations[0].captureTime = epoch.addingTimeInterval(10)
        try await store.ingest(batch([edited], scan: 10))
        try await store.ingest(batch([edited], scan: 11))
        // Even a failed/older collector can add provenance without undoing the edit.
        var failed = original
        failed.checkpoint = nil
        failed.status = .init(ok: false, code: .unreadable)
        try await store.ingest(failed)
        let results = try await allEvents(store)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.body, "Edited text")
        XCTAssertEqual(results.first?.observations.count, 2)
        XCTAssertEqual(results.first?.observations.first?.captureTime, epoch)
        let after = try await store.queue.read { db in try Data.fetchOne(db, sql: "SELECT json FROM event") }
        XCTAssertNotEqual(json, after)
        let checkpoint = try await store.checkpoint(for: .messages)
        XCTAssertEqual(checkpoint?.cursor, "synthetic:11.0")
    }

    func testIngestNeverDeletesForFailedIncompleteOrCompleteScans() async throws {
        let store = try open()
        try await store.ingest(batch([event(0), event(1)], complete: true))
        try await store.ingest(batch([event(0)], scan: 1))
        var failed = batch([event(2)], scan: 2, complete: true)
        failed.checkpoint = nil
        failed.status = .init(ok: false, code: .unreadable)
        try await store.ingest(failed)
        var results = try await allEvents(store)
        XCTAssertEqual(results.count, 3)
        let checkpoint = try await store.checkpoint(for: .messages)
        XCTAssertEqual(checkpoint?.scannedAt, epoch.addingTimeInterval(1))
        try await store.ingest(batch([event(0)], scan: 3, complete: true))
        results = try await allEvents(store)
        XCTAssertEqual(Set(results.map(\.id)), Set([event(0).id, event(1).id, event(2).id]))
        // An old complete scan cannot regress the checkpoint.
        try await store.ingest(batch([event(0), event(1)], scan: 0, complete: true))
        results = try await allEvents(store)
        XCTAssertEqual(results.count, 3)
        let latest = try await store.checkpoint(for: .messages)
        XCTAssertEqual(latest?.scannedAt, epoch.addingTimeInterval(3))
        XCTAssertEqual(latest?.complete, true)
    }

    func testCompleteEmptyBatchesPreserveAllEventsAndCitations() async throws {
        let store = try open()
        try await store.ingest(batch([event(0), event(1), event(2)], complete: true))
        try await store.ingest(batch([event(1)], source: .notifications, complete: true))
        try await store.saveBrief(brief(0, citing: [event(0).id]))
        try await store.ingest(batch(scan: 1, complete: true))
        var results = try await allEvents(store)
        XCTAssertEqual(Set(results.map(\.id)), Set([event(0).id, event(1).id, event(2).id]))
        try await store.ingest(batch(source: .notifications, scan: 2, complete: true))
        results = try await allEvents(store)
        XCTAssertEqual(Set(results.map(\.id)), Set([event(0).id, event(1).id, event(2).id]))
        let saved = try await store.latestBrief()
        XCTAssertEqual(saved, brief(0, citing: [event(0).id]))
    }

    func testDismissedNotificationSurvivesLaterCompleteBatchAndReopening() async throws {
        let store = try open()
        var notification = event(0, body: "DismissedNotificationToken")
        notification.source = .notification
        notification.id = EventID.make(source: .notification, sourceRecordID: notification.sourceRecordID)
        notification.eventTimeSource = .delivered
        notification.observations = [.init(route: .notificationDB, sourceRecordID: notification.sourceRecordID, captureTime: epoch)]
        try await store.ingest(batch([notification], source: .notifications, complete: true))
        try await store.ingest(batch(source: .notifications, scan: 1, complete: true))
        let reopened = try open()
        let events = try await allEvents(reopened)
        let matches = try await reopened.events(matching: "DismissedNotificationToken")
        XCTAssertEqual(events, [notification])
        XCTAssertEqual(matches, [notification])
    }

    func testInvalidBatchRollsBack() async throws {
        let store = try open()
        var invalid = event(2)
        invalid.id = "bad-id"
        do {
            try await store.ingest(batch([event(1), invalid]))
            XCTFail("expected invalid record")
        } catch { XCTAssertEqual(error as? StorageError, .invalidRecord) }
        let results = try await allEvents(store)
        let checkpoint = try await store.checkpoint(for: .messages)
        XCTAssertTrue(results.isEmpty)
        XCTAssertNil(checkpoint)
        var mismatch = batch()
        mismatch.checkpoint?.source = .mail
        do {
            try await store.ingest(mismatch)
            XCTFail("expected invalid batch")
        } catch { XCTAssertEqual(error as? StorageError, .invalidBatch) }
    }

    func testWindowBoundariesAndKeysetTies() async throws {
        let store = try open()
        try await store.ingest(batch([event(1, time: 2), event(2, time: 0), event(3, time: 1), event(4, time: 0)]))
        let window = try await store.events(from: epoch, to: epoch.addingTimeInterval(2))
        XCTAssertEqual(window.map(\.eventTime), [epoch, epoch, epoch.addingTimeInterval(1)])
        let page = try await store.events(from: epoch, to: epoch.addingTimeInterval(2), after: nil, limit: 1)
        let last = try XCTUnwrap(page.last)
        let rest = try await store.events(from: epoch, to: epoch.addingTimeInterval(2), after: EventCursor(after: last), limit: 10)
        XCTAssertEqual(page + rest, window)
        let empty = try await store.events(from: epoch, to: epoch)
        XCTAssertTrue(empty.isEmpty)
    }

    func testFractionalContractTimesDoNotRepeatAcrossPages() async throws {
        let store = try open()
        try await store.ingest(batch([event(1, time: 0.1234563), event(2, time: 0.1234564), event(3, time: 0.1234567)]))
        var cursor: EventCursor?
        var ids: [String] = []
        for _ in 0 ..< 4 {
            let page = try await store.events(from: epoch, to: epoch.addingTimeInterval(1), after: cursor, limit: 1)
            guard let last = page.last else { break }
            ids.append(last.id)
            cursor = EventCursor(after: last)
        }
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids), Set([event(1).id, event(2).id, event(3).id]))
    }

    func testMigrationsOnceAndInRegistrationOrder() async throws {
        XCTAssertTrue(try AegisStorage.hasFTS5())
        let store = try open()
        try await store.ingest(batch([event(0)]))
        var migrator = StorageSchema.migrator()
        migrator.registerMigration("v2-test") { db in
            // This depends on v1, proving registration order without adding a production migration.
            try db.execute(sql: "CREATE TABLE migrationWitness AS SELECT COUNT(*) AS count FROM event")
        }
        try migrator.migrate(store.queue)
        try migrator.migrate(store.queue)
        let registered = migrator
        let identifiers = try await store.queue.read { db in try registered.appliedIdentifiers(db) }
        XCTAssertEqual(identifiers, ["v1", "v2-test"])
        let witness = try await store.queue.read { db in try Int.fetchOne(db, sql: "SELECT count FROM migrationWitness") }
        XCTAssertEqual(witness, 1)
        let reopened = try open()
        let events = try await allEvents(reopened)
        XCTAssertEqual(events.count, 1)
    }
}
