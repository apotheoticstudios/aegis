import AegisKit
@testable import AegisStorage
import Foundation
import XCTest

@MainActor
class StorageTestCase: XCTestCase {
    nonisolated let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-storage-" + UUID().uuidString)
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func open(history: Int = 30, failure: (@Sendable (Int) throws -> Void)? = nil) throws -> GRDBEventStore {
        try GRDBEventStore(path: folder.appendingPathComponent("synthetic.sqlite").path, briefHistoryLimit: history, beforeRecord: failure)
    }

    func event(_ index: Int, time: Double = 0, capture: Double = 0, body: String = "Synthetic message") -> Event {
        Event(
            source: .imessage,
            sourceRecordID: "synthetic-\(index)",
            appID: nil,
            sender: "Synthetic sender",
            threadID: nil,
            eventTime: epoch.addingTimeInterval(time),
            eventTimeSource: .sent,
            captureTime: epoch.addingTimeInterval(capture),
            title: "Synthetic title",
            body: body,
            content: .complete,
            observations: [.init(route: .chatDB, sourceRecordID: "synthetic-\(index)", captureTime: epoch)]
        )
    }

    func batch(_ events: [Event] = [], source: SourceKind = .messages, scan: Double = 0, complete: Bool = false) -> CollectionBatch {
        CollectionBatch(
            source: source,
            status: .init(ok: true, code: .ok),
            events: events,
            checkpoint: .init(
                source: source,
                cursor: "synthetic:\(scan)",
                scannedAt: epoch.addingTimeInterval(scan),
                complete: complete
            )
        )
    }

    func brief(_ index: Int, citing ids: [String] = []) -> StoredBrief {
        StoredBrief(
            brief: Brief(
                generatedAt: epoch,
                windowStart: epoch.addingTimeInterval(-86400),
                windowEnd: epoch,
                model: nil,
                items: ids.isEmpty ? [] : [.init(text: "Synthetic summary", priority: .fyi, eventIDs: ids)],
                omittedEvents: 0
            ),
            inputRevision: "synthetic-\(index)",
            coverage: [.init(source: .messages, status: .ok, events: ids.count, lastSuccess: epoch)],
            storedAt: epoch.addingTimeInterval(Double(index))
        )
    }

    func allEvents(_ store: GRDBEventStore) async throws -> [Event] {
        try await store.events(from: epoch.addingTimeInterval(-100_000), to: epoch.addingTimeInterval(100_000))
    }

    /// An occurrence of a repeating item, originally scheduled at `original` (default: `start`, i.e. not moved).
    func occurrence(
        _ id: String, start: Double, end: Double, allDay: Bool = false, capture: Double = 0, original: Double? = nil
    ) -> CalendarOccurrence {
        CalendarOccurrence(
            itemID: id,
            occurrenceDate: epoch.addingTimeInterval(original ?? start),
            calendarTitle: "Synthetic calendar",
            title: "Synthetic appointment",
            start: epoch.addingTimeInterval(start),
            end: epoch.addingTimeInterval(end),
            isAllDay: allDay,
            timeZone: "UTC",
            location: nil,
            status: .confirmed,
            captureTime: epoch.addingTimeInterval(capture)
        )
    }

    func reminder(_ id: String, completed: Bool = false, at: Double? = nil) -> ReminderItem {
        ReminderItem(
            itemID: id,
            listTitle: nil,
            title: "Synthetic reminder",
            due: nil,
            isCompleted: completed,
            completedAt: at.map { epoch.addingTimeInterval($0) },
            priority: 0,
            captureTime: epoch
        )
    }
}
