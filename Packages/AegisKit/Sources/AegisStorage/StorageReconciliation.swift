import AegisKit
import Foundation
import GRDB

public extension GRDBEventStore {
    /// Deletes this source's unseen occurrences overlapping the half-open window, in one transaction.
    /// Includes zero-duration occurrences inside the window, matching schedule reads. Other sources
    /// and occurrences outside the window are untouched. Empty stores/windows are no-ops.
    /// Collectors must call only after ingesting every page of a complete scan of this source/window;
    /// `seen` contains all occurrence IDs observed across that scope, not just the last batch.
    func reconcileOccurrences(source: SourceKind, window: DateInterval, seen: Set<String>) async throws {
        try StorageDates.check([window.start, window.end])
        guard window.start < window.end else { return }
        try await reconcileSchedule(seen: seen, sql: """
        DELETE FROM occurrence WHERE source = ? AND start < ?
        AND (end > ? OR (start = end AND start >= ?))
        AND NOT EXISTS (SELECT 1 FROM scheduleSeen WHERE scheduleSeen.id = occurrence.id)
        """, arguments: [
            source.rawValue, window.end.timeIntervalSince1970,
            window.start.timeIntervalSince1970, window.start.timeIntervalSince1970,
        ])
    }

    /// Deletes only this source's unseen open reminders, in one transaction; empty stores are no-ops.
    /// Completed reminders remain available for completion-window queries. Other sources are untouched.
    /// Collectors must call only after ingesting every page of a complete scan of all open reminders
    /// for this source; `seen` contains all open reminder IDs observed, not just those due in a window.
    func reconcileOpenReminders(source: SourceKind, seen: Set<String>) async throws {
        try await reconcileSchedule(seen: seen, sql: """
        DELETE FROM reminder WHERE source = ? AND isCompleted = 0
        AND NOT EXISTS (SELECT 1 FROM scheduleSeen WHERE scheduleSeen.id = reminder.id)
        """, arguments: [source.rawValue])
    }

    private func reconcileSchedule(seen: Set<String>, sql: String, arguments: StatementArguments) async throws {
        try await queue.write { db in
            // A scoped temporary set avoids SQLite's bound-variable limit for large scans.
            try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS scheduleSeen(id TEXT PRIMARY KEY NOT NULL)")
            try db.execute(sql: "DELETE FROM scheduleSeen")
            for id in seen {
                try db.execute(sql: "INSERT INTO scheduleSeen(id) VALUES (?)", arguments: [id])
            }
            try db.execute(sql: sql, arguments: arguments)
            try db.execute(sql: "DELETE FROM scheduleSeen")
        }
    }
}
