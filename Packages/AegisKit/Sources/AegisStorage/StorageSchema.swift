import GRDB

// v1: contract JSON is authoritative; numeric UTC columns only support indexed window/version queries.
// Schedule source columns scope explicit reconciliation; events are removed only by retention.
// Brief citations have foreign keys so no deletion path can break a kept brief. FTS external content and
// GRDB's synchronization triggers follow every event insert, update and delete in the same transaction.
enum StorageSchema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE event (
                id TEXT NOT NULL UNIQUE, eventTime REAL NOT NULL, captureTime REAL NOT NULL,
                title TEXT, body TEXT NOT NULL, json BLOB NOT NULL
            );
            CREATE INDEX eventWindow ON event(eventTime, id);
            CREATE TABLE occurrence (
                id TEXT PRIMARY KEY NOT NULL, source TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL,
                captureTime REAL NOT NULL, json BLOB NOT NULL
            );
            CREATE INDEX occurrenceWindow ON occurrence(start, end);
            CREATE TABLE reminder (
                id TEXT PRIMARY KEY NOT NULL, source TEXT NOT NULL, isCompleted INTEGER NOT NULL, completedAt REAL,
                captureTime REAL NOT NULL, json BLOB NOT NULL
            );
            CREATE INDEX reminderWindow ON reminder(isCompleted, completedAt);
            CREATE TABLE checkpoint (source TEXT PRIMARY KEY NOT NULL, json BLOB NOT NULL);
            CREATE TABLE brief (id INTEGER PRIMARY KEY, storedAt REAL NOT NULL, json BLOB NOT NULL UNIQUE);
            CREATE INDEX briefHistory ON brief(storedAt DESC, id DESC);
            CREATE TABLE citation (
                briefID INTEGER NOT NULL REFERENCES brief(id) ON DELETE CASCADE,
                eventID TEXT NOT NULL REFERENCES event(id) ON DELETE RESTRICT,
                PRIMARY KEY(briefID, eventID)
            );
            CREATE INDEX citedEvent ON citation(eventID);
            """)
            try db.create(virtualTable: "eventSearch", using: FTS5()) { table in
                table.synchronize(withTable: "event")
                table.tokenizer = .unicode61(diacritics: .remove)
                table.column("title")
                table.column("body")
            }
        }
        return migrator
    }
}
