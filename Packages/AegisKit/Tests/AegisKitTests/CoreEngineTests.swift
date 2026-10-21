@testable import AegisKit
import Foundation
import XCTest

/// Step 3.1's synthetic vertical slice: fake sources → store → fake model → checked brief → the panel's
/// requests. Synthetic data only.
final class CoreEngineTests: XCTestCase {
    // 07:30 in Brisbane on 7 October (2026-10-06T21:30:00Z); the opening is 07:00, and the examples fall on 6 October.
    private let clock = TestClock(Date(timeIntervalSince1970: 1_791_322_200))
    private let brisbane = TimeZone(identifier: "Australia/Brisbane") ?? .gmt
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-engine-" + UUID().uuidString)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func engine(
        store: MemoryStore, model: any ModelClient, collectors: [any EventCollector]? = nil,
        persistence: (any SchedulePersistence)? = nil, pageSize: Int = 1000
    ) throws -> CoreEngine {
        try CoreEngine(
            store: store,
            collectors: collectors ?? [SyntheticCollector(source: .messages, events: exampleEvents())],
            model: model,
            persistence: persistence ?? ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: brisbane),
            options: .init(modelName: "synthetic-model", pageSize: pageSize),
            clock: clock.read
        )
    }

    func testRefreshPublishesABriefCitingTheCollectedEvent() async throws {
        let store = MemoryStore()
        let core = try engine(store: store, model: CitingModel())
        let reply = await core.handle(.refreshBrief(reason: .user))
        guard case .accepted = reply else {
            return XCTFail("expected accepted, got \(reply)")
        }
        await core.settle()
        let latest = try await store.latestBrief()
        let brief = try XCTUnwrap(latest?.brief)
        XCTAssertEqual(brief.items.count, 1)
        let cited = try XCTUnwrap(brief.items.first?.eventIDs.first)
        XCTAssertTrue(try exampleEvents().contains { $0.id == cited })
        XCTAssertEqual(brief.model, "synthetic-model")
        XCTAssertEqual(latest?.coverage.map(\.source), [.messages])
        // The panel reads the same brief over the Core service.
        let read = await core.handle(.latestBrief)
        XCTAssertEqual(read, .brief(latest))
        guard case let .status(status) = await core.handle(.status) else {
            return XCTFail("expected status")
        }
        XCTAssertFalse(status.generating)
        XCTAssertEqual(status.lastBriefAt, clock.read())
    }

    func testInvalidCitationOrFailedModelKeepsTheLastValidBrief() async throws {
        let store = MemoryStore()
        let first = try engine(store: store, model: CitingModel())
        _ = await first.handle(.refreshBrief(reason: .user))
        await first.settle()
        let kept = try await store.latestBrief()
        XCTAssertNotNil(kept)

        clock.advance(by: 3600)
        let inventing = try engine(store: store, model: CitingModel(invent: true))
        _ = await inventing.handle(.refreshBrief(reason: .user))
        await inventing.settle()
        let afterInventing = try await store.latestBrief()
        XCTAssertEqual(afterInventing, kept, "a draft citing an event outside its input is never published")

        clock.advance(by: 3600)
        let failing = try engine(store: store, model: FailingModel())
        _ = await failing.handle(.refreshBrief(reason: .user))
        await failing.settle()
        let afterFailing = try await store.latestBrief()
        XCTAssertEqual(afterFailing, kept)
        XCTAssertEqual(store.savedCount, 1)
    }

    func testRestartRestoresTheBriefAndTheSchedule() async throws {
        let store = MemoryStore()
        let first = try engine(store: store, model: CitingModel())
        _ = await first.handle(.refreshBrief(reason: .user))
        await first.settle()
        guard case let .status(before) = await first.handle(.status) else {
            return XCTFail("expected status")
        }
        // A new process: same database and schedule file, nothing in memory.
        let second = try engine(store: store, model: CitingModel())
        await second.start()
        guard case let .status(after) = await second.handle(.status) else {
            return XCTFail("expected status")
        }
        XCTAssertEqual(after.lastBriefAt, before.lastBriefAt)
        let restored = await second.handle(.latestBrief)
        let stored = try await store.latestBrief()
        XCTAssertEqual(restored, .brief(stored))
    }

    func testASecondRefreshWhileOneRunsIsRefused() async throws {
        let model = HeldModel()
        let core = try engine(store: MemoryStore(), model: model)
        guard case .accepted = await core.handle(.refreshBrief(reason: .user)) else {
            return XCTFail("expected the first refresh to be accepted")
        }
        await model.waitUntilRunning()
        let second = await core.handle(.refreshBrief(reason: .user))
        XCTAssertEqual(second, .refused(code: "already_generating"))
        guard case let .status(status) = await core.handle(.status) else {
            return XCTFail("expected status")
        }
        XCTAssertTrue(status.generating, "the panel can ask for status while the model runs")
        model.release()
        await core.settle()
    }

    func testSleepCancelsARunningJobAtOnceAndKeepsTheLastBrief() async throws {
        let store = MemoryStore()
        let model = HeldModel()
        let core = try engine(store: store, model: model)
        _ = await core.handle(.refreshBrief(reason: .user))
        await model.waitUntilRunning()
        // Must not wait for the job: sleep cancels it straight away.
        await core.sleep()
        await core.settle()
        XCTAssertTrue(model.wasCancelled)
        let latest = try await store.latestBrief()
        XCTAssertNil(latest)
        guard case let .status(status) = await core.handle(.status) else {
            return XCTFail("expected status")
        }
        XCTAssertFalse(status.generating)
    }

    func testAFailedSaveFreesTheSlotAndTheNextRefreshPublishes() async throws {
        let store = MemoryStore()
        store.failNextSave()
        let core = try engine(store: store, model: CitingModel())
        _ = await core.handle(.refreshBrief(reason: .user))
        await core.settle()
        let afterFailure = try await store.latestBrief()
        XCTAssertNil(afterFailure)
        guard case let .status(status) = await core.handle(.status) else {
            return XCTFail("expected status")
        }
        XCTAssertFalse(status.generating, "no reservation is left without a worker")
        // A user refresh bypasses the backoff and works once the store does.
        guard case .accepted = await core.handle(.refreshBrief(reason: .user)) else {
            return XCTFail("the slot must be free after a failed save")
        }
        await core.settle()
        let published = try await store.latestBrief()
        XCTAssertNotNil(published)
    }

    func testPagingTheStoreLeavesTheModelInputUnchanged() async throws {
        /// GRDB returns at most a page per call; here a page is 3 events. The engine must read every page,
        /// so the model gets exactly the input it would get from one big page, newest events included.
        func input(pageSize: Int, events: [Event]) async throws -> String {
            let model = RecordingModel()
            let core = try engine(
                store: MemoryStore(), model: model,
                collectors: [SyntheticCollector(source: .messages, events: events)], pageSize: pageSize
            )
            _ = await core.handle(.refreshBrief(reason: .user))
            await core.settle()
            return try XCTUnwrap(model.lastInput)
        }
        let examples = try exampleEvents()
        let paged = try await input(pageSize: 3, events: examples)
        let whole = try await input(pageSize: 1000, events: examples)
        XCTAssertEqual(paged, whole)
        XCTAssertGreaterThan(paged.components(separatedBy: "\n[ev_").count - 1, 3, "the input spans several pages")

        // Seven events at one instant span three pages; the (time, ID) keyset reaches them all.
        let instant = examples[0].eventTime
        let tied = (0 ..< 7).map { index in
            changed(examples[0], "tied-\(index)") {
                $0.body = "Synthetic tied message \(index)"
                $0.eventTime = instant
            }
        }
        let tiedInput = try await input(pageSize: 3, events: tied)
        for event in tied {
            XCTAssertTrue(tiedInput.contains(event.id), "\(event.id) at the shared instant reached the model")
        }
    }

    func testASaveFailureAfterPublishingNeverJamsTheSlot() async throws {
        let store = MemoryStore()
        let core = try engine(store: store, model: CitingModel(), persistence: FailsAfterPublish(folder: folder))
        _ = await core.handle(.refreshBrief(reason: .user))
        await core.settle()
        let published = try await store.latestBrief()
        XCTAssertNotNil(published, "the brief was stored before the failed save")
        guard case let .status(status) = await core.handle(.status) else {
            return XCTFail("expected status")
        }
        XCTAssertFalse(status.generating)
        clock.advance(by: 3600)
        guard case .accepted = await core.handle(.refreshBrief(reason: .user)) else {
            return XCTFail("the slot must be free after a late save failure")
        }
        await core.settle()
        XCTAssertEqual(store.savedCount, 2)
    }

    func testSleepDuringCollectionStopsTheModelFromStarting() async throws {
        let collector = HeldCollector()
        let model = RecordingModel()
        let store = MemoryStore()
        let core = try engine(store: store, model: model, collectors: [collector])
        _ = await core.handle(.refreshBrief(reason: .user))
        await collector.waitUntilRunning()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await core.sleep() }
            // Sleep's cancellation is recorded before the collector finishes.
            try? await Task.sleep(for: .milliseconds(100))
            collector.release()
        }
        await core.settle()
        XCTAssertNil(model.lastInput, "the model never started after sleep")
        let latest = try await store.latestBrief()
        XCTAssertNil(latest)
    }

    func testTicksNeverWaitForAJobAndCancelItAtTheDeadline() async throws {
        let model = HeldModel()
        let store = MemoryStore()
        let core = try engine(store: store, model: model)
        _ = await core.handle(.refreshBrief(reason: .user))
        await model.waitUntilRunning()
        await core.tick() // Returns at once: the job holds the lane.
        XCTAssertFalse(model.wasCancelled)
        clock.advance(by: 3600) // Past the job's deadline (the default job timeout is 10 minutes).
        await core.tick()
        XCTAssertTrue(model.wasCancelled, "the deadline tick cancels the running model")
        await core.settle()
        let latest = try await store.latestBrief()
        XCTAssertNil(latest)
    }

    func testAnUnwritableScheduleRefusesWorkAndNeverCallsTheModel() async throws {
        let model = RecordingModel()
        let core = try CoreEngine(
            store: MemoryStore(),
            collectors: [SyntheticCollector(source: .messages, events: exampleEvents())],
            model: model,
            persistence: UnwritableSchedule(),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: brisbane),
            options: .init(modelName: "synthetic-model"),
            clock: clock.read
        )
        let reply = await core.handle(.refreshBrief(reason: .user))
        XCTAssertEqual(reply, .refused(code: "schedule_unwritable"))
        await core.settle()
        await core.tick()
        XCTAssertNil(model.lastInput)
    }

    func testADraftRankingAPlantedOrderUrgentIsNeverPublished() async throws {
        let store = MemoryStore()
        let steered = try engine(store: store, model: SteeredModel())
        _ = await steered.handle(.refreshBrief(reason: .user))
        await steered.settle()
        let afterSteered = try await store.latestBrief()
        XCTAssertNil(afterSteered, "the brief checks reject an urgent planted order")
        clock.advance(by: 3600)
        let honest = try engine(store: store, model: CitingModel())
        _ = await honest.handle(.refreshBrief(reason: .user))
        await honest.settle()
        let published = try await store.latestBrief()
        XCTAssertNotNil(published)
    }

    func testSendersAreNamedFromContactsInTheInputAndTheSources() async throws {
        let examples = try exampleEvents()
        let incoming = try XCTUnwrap(examples.first { $0.senderHandle != nil && !SenderDisplay.isOutgoing($0) })
        let handle = try XCTUnwrap(incoming.senderHandle)
        let book = FixedContacts(index: ContactIndex([
            ContactSnapshot(id: "contact-1", displayName: "Robin Contact", phones: [handle], emails: [handle]),
        ]))
        let store = MemoryStore()
        let model = RecordingModel()
        let core = try CoreEngine(
            store: store, collectors: [SyntheticCollector(source: .messages, events: examples)], model: model,
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: brisbane),
            options: .init(modelName: "synthetic-model"), contacts: book, clock: clock.read
        )
        _ = await core.handle(.refreshBrief(reason: .user))
        await core.settle()
        let input = try XCTUnwrap(model.lastInput)
        let line = try XCTUnwrap(input.split(separator: "\n").first { $0.contains(incoming.id) })
        XCTAssertTrue(line.contains("from Robin Contact"), "the contact's name, not the handle")
        guard case let .events(sources) = await core.handle(.sources(ids: [incoming.id])) else {
            return XCTFail("expected events")
        }
        XCTAssertEqual(sources.first?.senderContact?.name, "Robin Contact")
    }

    func testHeatOrLowPowerDefersARefreshUntilBothClear() async throws {
        let store = MemoryStore()
        let model = RecordingModel()
        let core = try engine(store: store, model: model)
        await core.conditions(thermalSerious: true, lowPower: false)
        _ = await core.handle(.refreshBrief(reason: .user))
        await core.settle()
        XCTAssertNil(model.lastInput, "no generation while the Mac is too hot")
        await core.conditions(thermalSerious: false, lowPower: false)
        await core.settle()
        let published = try await store.latestBrief()
        XCTAssertNotNil(published, "the deferred brief runs once conditions clear")
    }

    func testThePanelGetsTodaysScheduleStraightFromTheStore() async throws {
        let store = MemoryStore()
        let start = clock.read()
        let meeting = CalendarOccurrence(
            itemID: "ITEM-1", occurrenceDate: nil, calendarTitle: "Work", title: "Synthetic meeting",
            start: start.addingTimeInterval(3600), end: start.addingTimeInterval(5400), isAllDay: false,
            timeZone: "Australia/Brisbane", location: nil, status: .confirmed, captureTime: start
        )
        let reminder = ReminderItem(
            itemID: "REM-1", listTitle: "Home", title: "Synthetic reminder", due: nil, isCompleted: false,
            completedAt: nil, priority: 0, captureTime: start
        )
        var batch = CollectionBatch(source: .calendar, status: SourceStatus(ok: true, code: .ok), checkpoint: nil)
        batch.occurrences = [meeting]
        try await store.ingest(batch)
        var reminders = CollectionBatch(source: .reminders, status: SourceStatus(ok: true, code: .ok), checkpoint: nil)
        reminders.reminders = [reminder]
        try await store.ingest(reminders)
        let core = try engine(store: store, model: CitingModel())
        let day = await core.handle(.schedule(from: start, to: start.addingTimeInterval(86400)))
        XCTAssertEqual(day, .schedule(occurrences: [meeting], reminders: [reminder]))
        let tooLong = await core.handle(.schedule(from: start, to: start.addingTimeInterval(8 * 86400)))
        XCTAssertEqual(tooLong, .refused(code: "bad_window"))
    }

    func testThePanelCanFetchTheEventsAnItemCites() async throws {
        let store = MemoryStore()
        let core = try engine(store: store, model: CitingModel())
        _ = await core.handle(.refreshBrief(reason: .user))
        await core.settle()
        let latest = try await store.latestBrief()
        let cited = try XCTUnwrap(latest?.brief.items.first?.eventIDs)
        guard case let .events(events) = await core.handle(.sources(ids: cited + ["ev_ffffffffffffffff"])) else {
            return XCTFail("expected events")
        }
        XCTAssertEqual(events.map(\.id), cited, "unknown IDs are left out")
        let tooMany = (0 ... CoreRequest.maxSourceIDs).map { String(format: "ev_%016x", $0) }
        let refused = await core.handle(.sources(ids: tooMany))
        XCTAssertEqual(refused, .refused(code: "too_many_ids"))
    }

    func testAnUnreadableSourceShowsInCoverageWithoutBlockingTheBrief() async throws {
        let store = MemoryStore()
        let core = try engine(store: store, model: CitingModel(), collectors: [
            SyntheticCollector(source: .messages, events: exampleEvents()),
            BrokenCollector(source: .mail),
        ])
        _ = await core.handle(.refreshBrief(reason: .user))
        await core.settle()
        let latest = try await store.latestBrief()
        XCTAssertNotNil(latest?.brief)
        let coverage = Dictionary(uniqueKeysWithValues: (latest?.coverage ?? []).map { ($0.source, $0.status) })
        XCTAssertEqual(coverage[.messages], .ok)
        XCTAssertEqual(coverage[.mail], .unreadable)
    }
}

// MARK: Synthetic parts

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(_ start: Date) {
        now = start
    }

    @Sendable func read() -> Date {
        lock.withLock { now }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { now = now.addingTimeInterval(seconds) }
    }
}

/// An in-memory `EventStore` with the same rules: replayed batches change nothing; only complete briefs
/// are saved.
final class MemoryStore: EventStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Event] = [:]
    private var checkpoints: [SourceKind: CollectionCheckpoint] = [:]
    private var occurrenceRecords: [String: CalendarOccurrence] = [:]
    private var reminderRecords: [String: ReminderItem] = [:]
    private var briefs: [StoredBrief] = []
    private var failingSaves = 0

    var savedCount: Int {
        lock.withLock { briefs.count }
    }

    func failNextSave() {
        lock.withLock { failingSaves += 1 }
    }

    func ingest(_ batch: CollectionBatch) async throws {
        lock.withLock {
            for event in batch.events {
                stored[event.id] = event
            }
            for occurrence in batch.occurrences {
                occurrenceRecords[occurrence.id] = occurrence
            }
            for reminder in batch.reminders {
                reminderRecords[reminder.id] = reminder
            }
            if let checkpoint = batch.checkpoint {
                checkpoints[batch.source] = checkpoint
            }
        }
    }

    func checkpoint(for source: SourceKind) async throws -> CollectionCheckpoint? {
        lock.withLock { checkpoints[source] }
    }

    func events(from start: Date, to end: Date) async throws -> [Event] {
        lock.withLock { window(start, end) }
    }

    func events(from start: Date, to end: Date, after cursor: EventCursor?, limit: Int) async throws -> [Event] {
        lock.withLock {
            let rest = window(start, end).filter { event in
                cursor.map { (event.eventTime, event.id) > ($0.time, $0.id) } ?? true
            }
            return Array(rest.prefix(limit))
        }
    }

    func events(ids: [String]) async throws -> [Event] {
        lock.withLock { ids.compactMap { stored[$0] } }
    }

    private func window(_ start: Date, _ end: Date) -> [Event] {
        stored.values.filter { $0.eventTime >= start && $0.eventTime < end }
            .sorted { ($0.eventTime, $0.id) < ($1.eventTime, $1.id) }
    }

    func occurrences(from start: Date, to end: Date) async throws -> [CalendarOccurrence] {
        lock.withLock {
            occurrenceRecords.values.filter { $0.start < end && ($0.end > start || $0.start == $0.end && $0.start >= start) }
                .sorted { $0.start < $1.start }
        }
    }

    func reminders(from start: Date, to end: Date) async throws -> [ReminderItem] {
        lock.withLock {
            reminderRecords.values.filter { !$0.isCompleted || ($0.completedAt.map { $0 >= start && $0 < end } ?? false) }
        }
    }

    func saveBrief(_ brief: StoredBrief) async throws {
        try lock.withLock {
            if failingSaves > 0 {
                failingSaves -= 1
                throw StoreUnavailable(code: .busy)
            }
            briefs.append(brief)
        }
    }

    func latestBrief() async throws -> StoredBrief? {
        lock.withLock { briefs.last }
    }
}

struct SyntheticCollector: EventCollector {
    let source: SourceKind
    let events: [Event]

    func collect(after _: CollectionCheckpoint?, now: Date) async throws -> CollectionBatch {
        CollectionBatch(
            source: source,
            status: SourceStatus(ok: true, code: .ok, count: events.count),
            events: events,
            checkpoint: CollectionCheckpoint(source: source, cursor: "synthetic", scannedAt: now, complete: true)
        )
    }
}

struct BrokenCollector: EventCollector {
    let source: SourceKind

    func collect(after _: CollectionCheckpoint?, now _: Date) async throws -> CollectionBatch {
        throw StoreUnavailable(code: .unreadable)
    }
}

/// Answers like the model would: one item citing the first event in its input, or an invented ID.
struct CitingModel: ModelClient {
    var invent = false

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        let first = job.user.range(of: #"ev_[0-9a-f]{16}"#, options: .regularExpression).map { String(job.user[$0]) }
        let cited = invent ? "ev_ffffffffffffffff" : (first ?? "ev_ffffffffffffffff")
        let answer = #"{"items": [{"text": "Synthetic summary.", "priority": "fyi", "event_ids": [""# + cited + #""]}]}"#
        return ModelJobResult(jobID: job.id, status: .completed, text: answer)
    }

    func cancel(jobID _: String) async {}
}

/// Writes the schedule file, except the first save after a brief was published.
final class FailsAfterPublish: SchedulePersistence, @unchecked Sendable {
    private let file: ScheduleFile
    private let lock = NSLock()
    private var failed = false

    init(folder: URL) {
        file = ScheduleFile(url: folder.appendingPathComponent("schedule.json"))
    }

    func load() throws -> BriefSchedule? {
        try file.load()
    }

    func save(_ schedule: BriefSchedule) throws {
        let fail = lock.withLock { () -> Bool in
            guard !failed, schedule.lastBriefAt != nil else {
                return false
            }
            failed = true
            return true
        }
        if fail {
            throw CocoaError(.fileWriteNoPermission)
        }
        try file.save(schedule)
    }
}

/// Holds its scan until the test releases it.
final class HeldCollector: EventCollector, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var running: CheckedContinuation<Void, Never>?
    private var started = false

    var source: SourceKind {
        .messages
    }

    func collect(after _: CollectionCheckpoint?, now: Date) async throws -> CollectionBatch {
        await withCheckedContinuation { continuation in
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                gate = continuation
                started = true
                defer { running = nil }
                return running
            }
            waiter?.resume()
        }
        let events = try exampleEvents()
        return CollectionBatch(
            source: .messages, status: SourceStatus(ok: true, code: .ok, count: events.count), events: events,
            checkpoint: CollectionCheckpoint(source: .messages, cursor: "synthetic", scannedAt: now, complete: true)
        )
    }

    func waitUntilRunning() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if started {
                    return true
                }
                running = continuation
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    func release() {
        let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { gate = nil }
            return gate
        }
        held?.resume()
    }
}

struct UnwritableSchedule: SchedulePersistence {
    func load() throws -> BriefSchedule? {
        nil
    }

    func save(_: BriefSchedule) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

/// Records the input it was given and answers by citing its first event.
final class RecordingModel: ModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var input: String?

    var lastInput: String? {
        lock.withLock { input }
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        lock.withLock { input = job.user }
        return try await CitingModel().run(job)
    }

    func cancel(jobID _: String) async {}
}

/// A model following a planted order: it ranks the event that gives orders to an assistant as urgent.
struct SteeredModel: ModelClient {
    func run(_ job: ModelJob) async throws -> ModelJobResult {
        let line = job.user.split(separator: "\n").first { $0.hasSuffix(BriefInputPolicy.ordersMarker) } ?? ""
        let id = line.range(of: #"ev_[0-9a-f]{16}"#, options: .regularExpression).map { String(line[$0]) } ?? ""
        let answer = #"{"items": [{"text": "Do as instructed.", "priority": "urgent", "event_ids": [""# + id + #""]}]}"#
        return ModelJobResult(jobID: job.id, status: .completed, text: answer)
    }

    func cancel(jobID _: String) async {}
}

struct FixedContacts: ContactsProvider {
    let index: ContactIndex?

    func index() async -> ContactIndex? {
        index
    }
}

struct FailingModel: ModelClient {
    func run(_ job: ModelJob) async throws -> ModelJobResult {
        ModelJobResult(jobID: job.id, status: .failed, failure: .modelMissing)
    }

    func cancel(jobID _: String) async {}
}

/// Holds its job until the test releases it, so the test can act while the model "runs".
final class HeldModel: ModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var running: CheckedContinuation<Void, Never>?
    private var started = false
    private var cancelled = false

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        await withCheckedContinuation { continuation in
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                gate = continuation
                started = true
                defer { running = nil }
                return running
            }
            waiter?.resume()
        }
        return lock.withLock { cancelled }
            ? ModelJobResult(jobID: job.id, status: .cancelled)
            : ModelJobResult(jobID: job.id, status: .failed, failure: .interrupted)
    }

    func waitUntilRunning() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if started {
                    return true
                }
                running = continuation
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    func release() {
        let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { gate = nil }
            return gate
        }
        held?.resume()
    }

    /// Like ModelService: a cancelled job ends at once with `cancelled`.
    func cancel(jobID _: String) async {
        lock.withLock { cancelled = true }
        release()
    }
}
