@testable import AegisKit
import Foundation
import XCTest

final class CoreEngineSourceHealthTests: XCTestCase {
    private let clock = TestClock(Date(timeIntervalSince1970: 1_791_320_400))

    private func engine(_ collectors: [any EventCollector], store: any EventStore = MemoryStore()) throws -> CoreEngine {
        let folder = try syntheticReaderFolder()
        return try CoreEngine(
            store: store, collectors: collectors, model: CitingModel(),
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 23, openingMinute: 0, timeZone: .gmt),
            options: .init(modelName: "synthetic"), clock: clock.read
        )
    }

    func testThrowingAndFailedCollectorsLeaveOtherCheckpointsWorking() async throws {
        let store = MemoryStore()
        let throwing = HealthCollector(source: .mail, failure: .throwing(.permissionDenied))
        let failed = HealthCollector(source: .notifications, failure: .status(.formatChanged))
        let healthy = HealthCollector(source: .messages)
        let core = try engine([throwing, failed, healthy], store: store)
        await core.collectSources()
        let status = await core.status()
        XCTAssertEqual(status.sources.map(\.status), [.permissionDenied, .noData, .formatChanged])
        let mailCheckpoint = try await store.checkpoint(for: .mail)
        let notificationCheckpoint = try await store.checkpoint(for: .notifications)
        let messagesCheckpoint = try await store.checkpoint(for: .messages)
        XCTAssertNil(mailCheckpoint)
        XCTAssertNil(notificationCheckpoint)
        XCTAssertEqual(messagesCheckpoint?.scannedAt, clock.read())
        XCTAssertEqual(status.sources.first { $0.source == .messages }?.lastSuccess, clock.read())
    }

    func testBackoffUsesOneFiveThenFifteenMinutesAndCaps() async throws {
        let failing = HealthCollector(source: .mail, failure: .throwing(.busy))
        let healthy = HealthCollector(source: .messages)
        let core = try engine([failing, healthy])
        await core.collectSources()
        for (delay, expectedAttempts) in [(60.0, 2), (300.0, 3), (900.0, 4), (900.0, 5)] {
            clock.advance(by: delay - 1)
            await core.collectSources()
            let before = await failing.attempts
            XCTAssertEqual(before.count, expectedAttempts - 1)
            clock.advance(by: 1)
            await core.collectSources()
            let after = await failing.attempts
            XCTAssertEqual(after.count, expectedAttempts)
            XCTAssertEqual(after.last, clock.read())
        }
        let goodAttempts = await healthy.attempts
        XCTAssertEqual(goodAttempts.count, 9, "other sources scan even during a source's backoff")
    }

    func testSuccessfulEmptyScanResetsBackoffAndKeepsCheckpointOnFailure() async throws {
        let store = MemoryStore()
        let collector = HealthCollector(source: .mail, failure: .status(.unreadable))
        let core = try engine([collector], store: store)
        await core.collectSources()
        clock.advance(by: 60)
        await collector.setFailure(.success)
        await core.collectSources()
        let committed = try await store.checkpoint(for: .mail)
        XCTAssertNotNil(committed)
        await collector.setFailure(.status(.unreadable))
        await core.collectSources()
        clock.advance(by: 59)
        await core.collectSources()
        let before = await collector.attempts
        XCTAssertEqual(before.count, 3)
        clock.advance(by: 1)
        await core.collectSources()
        let after = await collector.attempts
        let checkpoint = try await store.checkpoint(for: .mail)
        XCTAssertEqual(after.count, 4, "recovery resets the delay to one minute")
        XCTAssertEqual(checkpoint, committed)
        let inputs = await collector.checkpoints
        XCTAssertEqual(inputs.compactMap(\.self), [committed, committed].compactMap(\.self))
    }

    func testTickerRetriesWithoutARequestedBrief() async throws {
        let collector = HealthCollector(source: .mail, failure: .throwing(.busy))
        let core = try engine([collector])
        await core.collectSources()
        clock.advance(by: 59)
        await core.tick()
        await core.settle()
        let before = await collector.attempts
        XCTAssertEqual(before.count, 1)
        clock.advance(by: 1)
        await collector.setFailure(.success)
        await core.tick()
        await core.settle()
        let after = await collector.attempts
        XCTAssertEqual(after.count, 2)
        let status = await core.status()
        XCTAssertFalse(status.generating)
        XCTAssertEqual(status.sources.first?.status, .noData)
    }

    func testNeverSuccessfulSourceBecomesStaleAndRecovers() async throws {
        let failing = HealthCollector(source: .mail, failure: .status(.unreadable))
        let core = try engine([failing, HealthCollector(source: .messages)])
        await core.collectSources()
        clock.advance(by: 1799)
        await core.collectSources()
        var status = await core.status()
        XCTAssertEqual(status.sources.first?.status, .unreadable)
        clock.advance(by: 1)
        status = await core.status()
        XCTAssertEqual(status.sources.first?.status, .stale)
        XCTAssertNil(status.sources.first?.lastSuccess)
        clock.advance(by: 300)
        await failing.setFailure(.success)
        await core.collectSources()
        status = await core.status()
        XCTAssertEqual(status.sources.first?.status, .noData)
        XCTAssertEqual(status.sources.first?.lastSuccess, clock.read())
    }

    func testPriorSuccessStalesButSimultaneousFailureDoesNot() async throws {
        let mail = HealthCollector(source: .mail)
        let messages = HealthCollector(source: .messages)
        let core = try engine([mail, messages])
        await core.collectSources()
        let success = clock.read()
        await mail.setFailure(.throwing(.unreadable))
        await messages.setFailure(.throwing(.unreadable))
        clock.advance(by: 1800)
        await core.collectSources()
        var status = await core.status()
        XCTAssertEqual(status.sources.map(\.status), [.unreadable, .unreadable])
        await messages.setFailure(.success)
        clock.advance(by: 60)
        await core.collectSources()
        status = await core.status()
        XCTAssertEqual(status.sources.first?.status, .stale)
        XCTAssertEqual(status.sources.first?.lastSuccess, success)
    }

    func testStoreCheckpointAndIngestFailuresAreIsolated() async throws {
        for checkpointFailure in [true, false] {
            let store = HealthStore(failCheckpoint: checkpointFailure)
            let core = try engine([HealthCollector(source: .mail), HealthCollector(source: .messages)], store: store)
            await core.collectSources()
            let status = await core.status()
            let checkpoint = try await store.checkpoint(for: .messages)
            XCTAssertEqual(status.sources.map(\.status), [.busy, .noData])
            XCTAssertNotNil(checkpoint)
        }
    }

    func testPersistedCheckpointRestoresLastSuccessOnFailure() async throws {
        let store = MemoryStore()
        let lastScan = clock.read().addingTimeInterval(-1800)
        try await store.ingest(CollectionBatch(
            source: .mail, status: .init(ok: true, code: .noData),
            checkpoint: .init(source: .mail, cursor: "synthetic", scannedAt: lastScan, complete: false)
        ))
        let core = try engine([
            HealthCollector(source: .mail, failure: .throwing(.unreadable)), HealthCollector(source: .messages),
        ], store: store)
        await core.collectSources()
        let status = await core.status()
        XCTAssertEqual(status.sources.first?.status, .stale)
        XCTAssertEqual(status.sources.first?.lastSuccess, lastScan)
    }
}

private actor HealthCollector: EventCollector {
    enum Failure: Sendable {
        case success, throwing(SourceStatus.Code), status(SourceStatus.Code)
    }

    nonisolated let source: SourceKind
    var attempts: [Date] = []
    var checkpoints: [CollectionCheckpoint?] = []
    private var failure: Failure

    init(source: SourceKind, failure: Failure = .success) {
        self.source = source
        self.failure = failure
    }

    func setFailure(_ value: Failure) {
        failure = value
    }

    func collect(after checkpoint: CollectionCheckpoint?, now: Date) async throws -> CollectionBatch {
        attempts.append(now)
        checkpoints.append(checkpoint)
        let status: SourceStatus
        switch failure {
        case .success: status = .init(ok: true, code: .noData)
        case let .throwing(code): throw StoreUnavailable(code: code)
        case let .status(code): status = .init(ok: false, code: code)
        }
        // Even a faulty collector returning a checkpoint on failure must not advance the store.
        return CollectionBatch(
            source: source, status: status,
            checkpoint: .init(source: source, cursor: "synthetic", scannedAt: now, complete: true)
        )
    }
}

private struct HealthStore: EventStore {
    let memory = MemoryStore()
    let failCheckpoint: Bool

    func ingest(_ batch: CollectionBatch) async throws {
        if !failCheckpoint, batch.source == .mail {
            throw StoreUnavailable(code: .busy)
        }
        try await memory.ingest(batch)
    }

    func checkpoint(for source: SourceKind) async throws -> CollectionCheckpoint? {
        if failCheckpoint, source == .mail {
            throw StoreUnavailable(code: .busy)
        }
        return try await memory.checkpoint(for: source)
    }

    func events(from start: Date, to end: Date) async throws -> [Event] {
        try await memory.events(from: start, to: end)
    }

    func events(from start: Date, to end: Date, after cursor: EventCursor?, limit: Int) async throws -> [Event] {
        try await memory.events(from: start, to: end, after: cursor, limit: limit)
    }

    func events(ids: [String]) async throws -> [Event] {
        try await memory.events(ids: ids)
    }

    func occurrences(from start: Date, to end: Date) async throws -> [CalendarOccurrence] {
        try await memory.occurrences(from: start, to: end)
    }

    func reminders(from start: Date, to end: Date) async throws -> [ReminderItem] {
        try await memory.reminders(from: start, to: end)
    }

    func saveBrief(_ brief: StoredBrief) async throws {
        try await memory.saveBrief(brief)
    }

    func latestBrief() async throws -> StoredBrief? {
        try await memory.latestBrief()
    }
}
