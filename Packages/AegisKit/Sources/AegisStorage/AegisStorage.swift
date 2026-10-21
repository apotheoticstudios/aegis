import AegisKit
import GRDB

/// AegisCore's database (ADR-0012): events, schedule records, checkpoints and finished briefs, with FTS5
/// search, on GRDB. AegisCore is its only writer. The store itself is step 2.7 of `docs/stages/STAGE-1.md`.
public enum AegisStorage {
    /// Whether this platform's SQLite has FTS5, which the store's search needs.
    public static func hasFTS5() throws -> Bool {
        let queue = try DatabaseQueue()
        return try queue.read { db in try Int.fetchOne(db, sql: "SELECT sqlite_compileoption_used('ENABLE_FTS5')") == 1 }
    }
}
