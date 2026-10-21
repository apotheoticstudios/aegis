import AegisKit
import Foundation
import GRDB

extension GRDBEventStore {
    /// Upserts records and stores their checkpoint in one transaction; never deletes records.
    /// Checkpoint completeness describes the collector scan, not a request to mirror source deletions.
    public func ingest(_ batch: CollectionBatch) async throws {
        guard batch.checkpoint == nil || (batch.checkpoint?.source == batch.source && batch.status.ok),
              batch.occurrences.isEmpty || batch.source == .calendar,
              batch.reminders.isEmpty || batch.source == .reminders
        else { throw StorageError.invalidBatch }
        try await queue.write { db in
            let previous = try Self.checkpoint(db, source: batch.source)
            // Older scans/replays must not roll back a newer checkpoint.
            if let checkpoint = batch.checkpoint, let previous, checkpoint.scannedAt < previous.scannedAt {
                return
            }
            var index = 0
            for event in batch.events {
                try self.beforeRecord?(index)
                index += 1
                try Self.store(event, db: db)
            }
            for occurrence in batch.occurrences {
                try self.beforeRecord?(index)
                index += 1
                try Self.store(occurrence, source: batch.source, db: db)
            }
            for reminder in batch.reminders {
                try self.beforeRecord?(index)
                index += 1
                try Self.store(reminder, source: batch.source, db: db)
            }
            if let checkpoint = batch.checkpoint {
                try db.execute(sql: """
                INSERT INTO checkpoint(source, json) VALUES (?, ?)
                ON CONFLICT(source) DO UPDATE SET json = excluded.json WHERE json != excluded.json
                """, arguments: [batch.source.rawValue, IPCCoding.encode(checkpoint)])
            }
        }
    }

    private static func store(_ occurrence: CalendarOccurrence, source: SourceKind, db: Database) throws {
        try StorageDates.check([occurrence.start, occurrence.end, occurrence.captureTime])
        guard occurrence.validate().isEmpty else { throw StorageError.invalidRecord }
        try db.execute(sql: """
        INSERT INTO occurrence(id, source, start, end, captureTime, json) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET start = excluded.start, end = excluded.end,
        captureTime = excluded.captureTime, json = excluded.json
        WHERE excluded.captureTime > occurrence.captureTime AND excluded.json != occurrence.json
        """, arguments: [
            occurrence.id,
            source.rawValue,
            StorageDates.seconds(occurrence.start),
            StorageDates.seconds(occurrence.end),
            StorageDates.seconds(occurrence.captureTime),
            IPCCoding.encode(occurrence),
        ])
    }

    private static func store(_ reminder: ReminderItem, source: SourceKind, db: Database) throws {
        try StorageDates.check([reminder.captureTime, reminder.completedAt, reminder.due?.date])
        guard reminder.validate().isEmpty else { throw StorageError.invalidRecord }
        try db.execute(sql: """
        INSERT INTO reminder(id, source, isCompleted, completedAt, captureTime, json) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET isCompleted = excluded.isCompleted, completedAt = excluded.completedAt,
        captureTime = excluded.captureTime, json = excluded.json
        WHERE excluded.captureTime > reminder.captureTime AND excluded.json != reminder.json
        """, arguments: [
            reminder.id,
            source.rawValue,
            reminder.isCompleted,
            reminder.completedAt.map(StorageDates.seconds),
            StorageDates.seconds(reminder.captureTime),
            IPCCoding.encode(reminder),
        ])
    }

    private static func store(_ incoming: Event, db: Database) throws {
        try StorageDates.check([incoming.eventTime, incoming.captureTime] + incoming.observations.map(\.captureTime))
        guard incoming.validate().isEmpty else { throw StorageError.invalidRecord }
        let data = try Data.fetchOne(db, sql: "SELECT json FROM event WHERE id = ?", arguments: [incoming.id])
        let existing = try data.map { try IPCCoding.decode(Event.self, from: $0) }
        // Capture time is the v0.2 contract's available version stamp. Older replays can add routes,
        // but cannot overwrite a newer edit. Equal stamps keep the first version deterministically.
        var event = existing
            .map { StorageDates.seconds(incoming.captureTime) > StorageDates.seconds($0.captureTime) ? incoming : $0 } ?? incoming
        // Observation identity is (route, sourceRecordID), not when a repeated scan captured it.
        // Keep the earliest capture of each route/record, and a stable order for byte-identical replays.
        var observations: [String: Event.Observation] = [:]
        for observation in (existing?.observations ?? []) + incoming.observations {
            let key = observation.route.rawValue + "\u{1F}" + observation.sourceRecordID
            if let old = observations[key], old.captureTime <= observation.captureTime {
                continue
            }
            observations[key] = observation
        }
        event.observations = observations.values.sorted {
            ($0.route.rawValue, $0.sourceRecordID) < ($1.route.rawValue, $1.sourceRecordID)
        }
        try db.execute(sql: """
        INSERT INTO event(id, eventTime, captureTime, title, body, json) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET eventTime = excluded.eventTime, captureTime = excluded.captureTime,
        title = excluded.title, body = excluded.body, json = excluded.json WHERE event.json != excluded.json
        """, arguments: [
            event.id,
            StorageDates.seconds(event.eventTime),
            StorageDates.seconds(event.captureTime),
            event.title,
            event.body,
            IPCCoding.encode(event),
        ])
    }
}
