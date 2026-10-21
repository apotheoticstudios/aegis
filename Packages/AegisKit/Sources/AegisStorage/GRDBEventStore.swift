import AegisKit
import Foundation
import GRDB

/// Invalid storage input, expressed without collected text.
public enum StorageError: Error, Sendable, Equatable {
    case invalidBatch, invalidRecord, incompleteBrief, invalidLimit, invalidHorizon
}

/// AegisCore's one serialized writer (ADR-0012). All work runs on DatabaseQueue's executor.
///
/// Windows are half-open [start, end). Protocol event reads return at most 1,000 records; use the
/// cursor overload for larger windows. Schedule reads likewise cap at 1,000; their overloads allow
/// offset paging. Each ingest encodes only one record at a time; collectors should supply bounded batches.
/// Ingest never deletes records, regardless of checkpoint completeness. Events survive source dismissal
/// or deletion until retention removes them. Schedule removals require explicit reconciliation after a
/// complete scan of the specified occurrence window or all open reminders for that source.
public final class GRDBEventStore: EventStore {
    public static let pageSize = 1000
    let queue: DatabaseQueue
    private let briefHistoryLimit: Int
    let beforeRecord: (@Sendable (Int) throws -> Void)?

    /// Opens a database at a caller-owned private path and applies ordered migrations.
    /// History retains the newest complete briefs by `storedAt` (default 30).
    public convenience init(path: String, briefHistoryLimit: Int = 30) throws {
        try self.init(path: path, briefHistoryLimit: briefHistoryLimit, beforeRecord: nil)
    }

    /// Internal failure injection tests transaction rollback without production-only failure switches.
    init(path: String, briefHistoryLimit: Int = 30, beforeRecord: (@Sendable (Int) throws -> Void)?) throws {
        guard briefHistoryLimit > 0 else { throw StorageError.invalidLimit }
        queue = try DatabaseQueue(path: path)
        self.briefHistoryLimit = briefHistoryLimit
        self.beforeRecord = beforeRecord
        try StorageSchema.migrator().migrate(queue)
    }

    public func checkpoint(for source: SourceKind) async throws -> CollectionCheckpoint? {
        try await queue.read { db in try Self.checkpoint(db, source: source) }
    }

    static func checkpoint(_ db: Database, source: SourceKind) throws -> CollectionCheckpoint? {
        try Data.fetchOne(db, sql: "SELECT json FROM checkpoint WHERE source = ?", arguments: [source.rawValue])
            .map { try IPCCoding.decode(CollectionCheckpoint.self, from: $0) }
    }

    public func events(from start: Date, to end: Date) async throws -> [Event] {
        try await events(from: start, to: end, after: nil, limit: Self.pageSize)
    }

    /// The stored events with these IDs (unknown IDs are left out), looked up in chunks under SQLite's
    /// bound-parameter limit.
    public func events(ids: [String]) async throws -> [Event] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else {
            return []
        }
        return try await queue.read { db in
            var events: [Event] = []
            for start in stride(from: 0, to: unique.count, by: 500) {
                let chunk = Array(unique[start ..< min(start + 500, unique.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                events += try Self.decodeRows(
                    Event.self, db: db, sql: "SELECT json FROM event WHERE id IN (\(marks))",
                    arguments: StatementArguments(chunk)
                )
            }
            return events
        }
    }

    /// Reads one bounded page without OFFSET or decoding earlier pages. Concurrent edits can change pages;
    /// callers needing a stable snapshot must avoid ingest/maintenance during traversal.
    public func events(from start: Date, to end: Date, after cursor: EventCursor?, limit: Int) async throws -> [Event] {
        try Self.checkLimit(limit)
        return try await queue.read { db in
            var sql = "SELECT json FROM event WHERE eventTime >= ? AND eventTime < ?"
            var arguments: StatementArguments = [start.timeIntervalSince1970, end.timeIntervalSince1970]
            if let cursor {
                sql += " AND (eventTime, id) > (?, ?)"
                arguments += [cursor.time.timeIntervalSince1970, cursor.id]
            }
            sql += " ORDER BY eventTime, id LIMIT ?"
            arguments += [limit]
            return try Self.decodeRows(Event.self, db: db, sql: sql, arguments: arguments)
        }
    }

    public func occurrences(from start: Date, to end: Date) async throws -> [CalendarOccurrence] {
        try await occurrences(from: start, to: end, limit: Self.pageSize, offset: 0)
    }

    /// Includes overlapping timed/all-day intervals and zero-duration items inside the window.
    public func occurrences(from start: Date, to end: Date, limit: Int, offset: Int) async throws -> [CalendarOccurrence] {
        try Self.checkLimit(limit, offset: offset)
        guard start < end else { return [] }
        return try await queue.read { db in
            try Self.decodeRows(CalendarOccurrence.self, db: db, sql: """
            SELECT json FROM occurrence WHERE start < ? AND (end > ? OR (start = end AND start >= ?))
            ORDER BY start, id LIMIT ? OFFSET ?
            """, arguments: [end.timeIntervalSince1970, start.timeIntervalSince1970, start.timeIntervalSince1970, limit, offset])
        }
    }

    public func reminders(from start: Date, to end: Date) async throws -> [ReminderItem] {
        try await reminders(from: start, to: end, limit: Self.pageSize, offset: 0)
    }

    /// Open reminders are included regardless of due date; completed ones require a completion in the window.
    public func reminders(from start: Date, to end: Date, limit: Int, offset: Int) async throws -> [ReminderItem] {
        try Self.checkLimit(limit, offset: offset)
        return try await queue.read { db in
            try Self.decodeRows(ReminderItem.self, db: db, sql: """
            SELECT json FROM reminder WHERE isCompleted = 0 OR (completedAt >= ? AND completedAt < ?)
            ORDER BY id LIMIT ? OFFSET ?
            """, arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970, limit, offset])
        }
    }

    /// Treats query text as literal Unicode tokens, never SQL or FTS operators. Empty/punctuation queries return no rows.
    public func events(matching query: String, limit: Int = pageSize) async throws -> [Event] {
        try Self.checkLimit(limit)
        guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }
        return try await queue.read { db in
            try Self.decodeRows(Event.self, db: db, sql: """
            SELECT event.json FROM event JOIN eventSearch ON eventSearch.rowid = event.rowid
            WHERE eventSearch MATCH ? ORDER BY event.eventTime, event.id LIMIT ?
            """, arguments: [pattern, limit])
        }
    }

    /// Literal FTS tokens restricted to a half-open window, newest first.
    public func search(_ text: String, from start: Date, to end: Date, limit: Int) async throws -> [Event] {
        try Self.checkLimit(limit)
        guard start < end, let pattern = FTS5Pattern(matchingAllTokensIn: text) else { return [] }
        return try await queue.read { db in
            try Self.decodeRows(Event.self, db: db, sql: """
            SELECT event.json FROM event JOIN eventSearch ON eventSearch.rowid = event.rowid
            WHERE eventSearch MATCH ? AND event.eventTime >= ? AND event.eventTime < ?
            ORDER BY event.eventTime DESC, event.id LIMIT ?
            """, arguments: [pattern, start.timeIntervalSince1970, end.timeIntervalSince1970, limit])
        }
    }

    /// StoredBrief has no completion bit: completeness means a valid finished contract, a nonempty input
    /// revision, and every citation present. Unavailable source coverage is valid and remains visible.
    /// Invalid/incomplete input throws and leaves the previous brief and history untouched.
    public func saveBrief(_ brief: StoredBrief) async throws {
        try StorageDates.check([brief.brief.generatedAt, brief.brief.windowStart, brief.brief.windowEnd])
        try await queue.write { db in
            var known = Set<String>()
            for item in brief.brief.items {
                for id in item.eventIDs where try Bool.fetchOne(
                    db, sql: "SELECT EXISTS(SELECT 1 FROM event WHERE id = ?)", arguments: [id]
                ) == true {
                    known.insert(id)
                }
            }
            guard !brief.inputRevision.isEmpty, brief.brief.validate(knownEventIDs: known).isEmpty else {
                throw StorageError.incompleteBrief
            }
            try db.execute(
                sql: "INSERT OR IGNORE INTO brief(storedAt, json) VALUES (?, ?)",
                arguments: [brief.storedAt.timeIntervalSince1970, IPCCoding.encode(brief)]
            )
            if db.changesCount > 0 {
                let briefID = db.lastInsertedRowID
                for id in known {
                    try db.execute(sql: "INSERT INTO citation(briefID, eventID) VALUES (?, ?)", arguments: [briefID, id])
                }
            }
            try db.execute(sql: """
            DELETE FROM brief WHERE id NOT IN (SELECT id FROM brief ORDER BY storedAt DESC, id DESC LIMIT ?)
            """, arguments: [self.briefHistoryLimit])
        }
    }

    public func latestBrief() async throws -> StoredBrief? {
        try await briefs(limit: 1).first
    }

    /// Kept brief history, newest first; bounded by both the requested limit and configured history.
    public func briefs(limit: Int = 30) async throws -> [StoredBrief] {
        try Self.checkLimit(limit)
        return try await queue.read { db in
            try Self.decodeRows(
                StoredBrief.self,
                db: db,
                sql: "SELECT json FROM brief ORDER BY storedAt DESC, id DESC LIMIT ?",
                arguments: [limit]
            )
        }
    }

    /// Deletes at most `limit` oldest events before `now - horizon`, excluding every kept citation.
    /// Call repeatedly for large backlogs. Event deletions and FTS index updates are atomic.
    @discardableResult
    public func maintain(horizon: TimeInterval, now: Date = Date(), limit: Int = pageSize) async throws -> Int {
        try Self.checkLimit(limit)
        guard horizon.isFinite, horizon >= 0 else { throw StorageError.invalidHorizon }
        return try await queue.write { db in
            try db.execute(sql: """
            DELETE FROM event WHERE id IN (
                SELECT id FROM event WHERE eventTime < ?
                AND NOT EXISTS (SELECT 1 FROM citation WHERE eventID = event.id)
                ORDER BY eventTime, id LIMIT ?
            )
            """, arguments: [now.addingTimeInterval(-horizon).timeIntervalSince1970, limit])
            return db.changesCount
        }
    }

    private static func checkLimit(_ limit: Int, offset: Int = 0) throws {
        guard (1 ... pageSize).contains(limit), offset >= 0 else { throw StorageError.invalidLimit }
    }

    private static func decodeRows<Value: Decodable>(
        _ type: Value.Type, db: Database, sql: String, arguments: StatementArguments
    ) throws -> [Value] {
        // A cursor decodes each row directly into the bounded output; no intermediate JSON array.
        let cursor = try Data.fetchCursor(db, sql: sql, arguments: arguments)
        var values: [Value] = []
        while let data = try cursor.next() {
            try values.append(IPCCoding.decode(type, from: data))
        }
        return values
    }
}
