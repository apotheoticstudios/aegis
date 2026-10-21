import CSQLite
import Foundation

/// Disk-backed duplicate counts and selection facts; no corpus-sized dictionary is retained.
/// The indexed database and facts spool share the private scratch directory, removed on every exit path.
final class NoiseSelectionScratch {
    struct Facts {
        var key: String
        var thread: String?
        var noise: Bool
        var question: Bool
    }

    private let file: FileHandle
    private var database: OpaquePointer?
    private var upsert: OpaquePointer?
    private var lookup: OpaquePointer?
    private var writing = true
    private var lastSender: (text: String, key: String)?
    private var lastThread: (text: String, key: String)?
    private static let keyLength = "duplicate-".utf8.count + 128

    init(folder: URL) throws {
        let path = folder.appendingPathComponent("selection").path
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw PipelineError.scratchStorage
        }
        file = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        do {
            let store = folder.appendingPathComponent("duplicates.sqlite").path
            guard FileManager.default.createFile(atPath: store, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw PipelineError.scratchStorage
            }
            try check(sqlite3_open_v2(store, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil))
            // A fixed page cache keeps RAM independent of the number of distinct duplicate keys.
            try execute("PRAGMA cache_size = -8192")
            // Apple's default spill threshold can exceed the cache limit by thousands of pages.
            try execute("PRAGMA cache_spill = 1")
            try execute("PRAGMA mmap_size = 0")
            // This store is discarded on every exit; a failed build never needs crash recovery.
            try execute("PRAGMA journal_mode = OFF")
            // The WITHOUT ROWID primary key is the index used by both upsert and lookup.
            try execute("""
            CREATE TABLE duplicates (key TEXT PRIMARY KEY, id TEXT, time REAL, rank INTEGER, orders INTEGER, count INTEGER) WITHOUT ROWID
            """)
            // UTF-8 BINARY order matches scalarLess, including canonically distinct IDs.
            let replace = """
            ?6 AND (excluded.orders > duplicates.orders OR (excluded.orders = duplicates.orders AND
                (excluded.time > duplicates.time OR (excluded.time = duplicates.time AND
                    CASE WHEN excluded.rank IS NOT NULL AND duplicates.rank IS NOT NULL AND excluded.rank != duplicates.rank
                        THEN excluded.rank < duplicates.rank ELSE duplicates.id < excluded.id COLLATE BINARY END))))
            """
            upsert = try prepare("""
            INSERT INTO duplicates VALUES (?1, ?2, ?3, ?4, ?5, 1)
            ON CONFLICT(key) DO UPDATE SET
                id = CASE WHEN \(replace) THEN excluded.id ELSE duplicates.id END,
                time = CASE WHEN \(replace) THEN excluded.time ELSE duplicates.time END,
                rank = CASE WHEN \(replace) THEN excluded.rank ELSE duplicates.rank END,
                orders = CASE WHEN \(replace) THEN excluded.orders ELSE duplicates.orders END,
                count = duplicates.count + 1
            """)
            lookup = try prepare("SELECT id, count FROM duplicates WHERE key = ?1")
            try execute("BEGIN TRANSACTION")
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    /// Finalize before the owning scratch directory is removed, including on a failed build.
    func close() {
        if let upsert {
            sqlite3_finalize(upsert)
        }
        if let lookup {
            sqlite3_finalize(lookup)
        }
        if let database {
            sqlite3_close_v2(database)
        }
        upsert = nil
        lookup = nil
        database = nil
        try? file.close()
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw SQLiteError(code: code) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            if let statement {
                sqlite3_finalize(statement)
            }
            throw SQLiteError(code: code)
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE {
                return
            }
            guard code == SQLITE_ROW else { throw SQLiteError(code: code) }
        }
    }

    private func bind(_ text: String, to statement: OpaquePointer, at index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try check(text.utf8CString.withUnsafeBufferPointer {
            sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), transient)
        })
    }

    /// Only one short thread and sender are cached; unique or oversized values cannot grow RAM.
    func threadKey(_ thread: String?) -> String? {
        guard let thread, !thread.isEmpty else { return nil }
        if let lastThread, lastThread.text.utf8.elementsEqual(thread.utf8) {
            return lastThread.key
        }
        let key = SHA256.hex(Array(thread.utf8))
        if thread.utf8.count <= 1024 {
            lastThread = (thread, key)
        }
        return key
    }

    func append(
        _ event: Event, rank: Int?, renderable: Bool, thread: String?, trusted: Set<String> = [], vip: Bool = false
    ) throws {
        // Unknown senders are isolated by app/source; known handles take precedence over display names.
        let sender = event.senderHandle ?? event.sender ?? "\(event.source.rawValue):\(event.appID ?? "")"
        let senderKey: String
        if let lastSender, lastSender.text.utf8.elementsEqual(sender.utf8) {
            senderKey = lastSender.key
        } else {
            senderKey = Self.digest(sender)
            if sender.utf8.count <= 1024 {
                lastSender = (sender, senderKey)
            }
        }
        let key = "duplicate-" + senderKey + Self.digest(event.body)
        let orders = BriefInputPolicy.givesOrders(event)
        guard writing, let upsert else { throw PipelineError.scratchStorage }
        defer { sqlite3_reset(upsert); sqlite3_clear_bindings(upsert) }
        try bind(key, to: upsert, at: 1)
        try bind(renderable ? event.id : "", to: upsert, at: 2)
        try check(sqlite3_bind_double(upsert, 3, (renderable ? event.eventTime : .distantPast).timeIntervalSinceReferenceDate))
        try check(rank.map { sqlite3_bind_int64(upsert, 4, Int64($0)) } ?? sqlite3_bind_null(upsert, 4))
        try check(sqlite3_bind_int(upsert, 5, renderable && orders ? 1 : 0))
        try check(sqlite3_bind_int(upsert, 6, renderable ? 1 : 0))
        let code = sqlite3_step(upsert)
        guard code == SQLITE_DONE else { throw SQLiteError(code: code) }
        guard renderable else { return }
        // Fixed-width hexadecimal keys and one flag byte need no per-event JSON codec or framing.
        var data = Data(key.utf8)
        data.append(contentsOf: (thread ?? String(repeating: "0", count: 64)).utf8)
        data
            .append((!vip && NoiseRules.isNoise(event, trusted: trusted) ? 1 : 0) | (BriefInputPolicy.asksOwner(event) ? 2 : 0) |
                (thread != nil ? 4 : 0))
        try file.write(contentsOf: data)
    }

    /// Chained fixed-size SHA-256 blocks fingerprint the full body without allocating its UTF-8 bytes as a whole.
    /// The chain's starting value, computed once instead of per call.
    private static let emptyDigest = SHA256.hex([])

    private static func digest(_ text: String) -> String {
        var digest = emptyDigest, block: [UInt8] = []
        for byte in text.utf8 {
            block.append(byte)
            if block.count == 1024 {
                digest = SHA256.hex(Array(digest.utf8) + block)
                block.removeAll(keepingCapacity: true)
            }
        }
        return SHA256.hex(Array(digest.utf8) + block)
    }

    func rewind() throws {
        if writing {
            try execute("COMMIT")
            writing = false
        }
        try file.seek(toOffset: 0)
    }

    func next() throws -> Facts {
        func read(_ size: Int) throws -> Data {
            var result = Data()
            while result.count < size {
                guard let bytes = try file.read(upToCount: size - result.count), !bytes.isEmpty else {
                    throw PipelineError.scratchStorage
                }
                result.append(bytes)
            }
            return result
        }
        let data = try read(Self.keyLength + 65)
        let flags = data[Self.keyLength + 64]
        guard flags < 8 else { throw PipelineError.scratchStorage }
        // swiftlint:disable optional_data_string_conversion
        return Facts(
            key: String(decoding: data.prefix(Self.keyLength), as: UTF8.self),
            thread: flags & 4 == 0 ? nil : String(decoding: data[Self.keyLength ..< Self.keyLength + 64], as: UTF8.self),
            noise: flags & 1 != 0, question: flags & 2 != 0
        )
        // swiftlint:enable optional_data_string_conversion
    }

    func duplicateCount(_ facts: Facts, id: String) throws -> Int? {
        guard let lookup else { throw PipelineError.scratchStorage }
        defer { sqlite3_reset(lookup); sqlite3_clear_bindings(lookup) }
        try bind(facts.key, to: lookup, at: 1)
        let code = sqlite3_step(lookup)
        guard code == SQLITE_ROW else { throw SQLiteError(code: code) }
        guard let bytes = sqlite3_column_text(lookup, 0) else { throw PipelineError.scratchStorage }
        // Preserve Swift's canonical String equality when checking the winning ID.
        // swiftlint:disable:next optional_data_string_conversion
        let winner = String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(lookup, 0))), as: UTF8.self)
        return winner == id ? Int(sqlite3_column_int64(lookup, 1)) : nil
    }

    /// Keep a min-heap of the newest candidates in O(log(limit)) work per record.
    static func retainNewest<Row>(_ row: Row, in heap: inout [Row], limit: Int, less: (Row, Row) -> Bool) {
        guard limit > 0 else { return }
        if heap.count < limit {
            heap.append(row)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard less(heap[child], heap[parent]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        } else if let first = heap.first, less(first, row) {
            heap[0] = row
            var parent = 0
            while parent * 2 + 1 < heap.count {
                var child = parent * 2 + 1
                if child + 1 < heap.count, less(heap[child + 1], heap[child]) {
                    child += 1
                }
                guard less(heap[child], heap[parent]) else { break }
                heap.swapAt(child, parent)
                parent = child
            }
        }
    }

    /// Add the count within perEvent, shortening only the JSON body and preserving rule markers.
    static func countedLine(_ line: String, count: Int, limit: Int) -> String? {
        guard count > 1 else { return line }
        let countSuffix = " · (×\(count))"
        if line.unicodeScalars.count + countSuffix.unicodeScalars.count <= limit {
            return line + countSuffix
        }
        let marker = [BriefInputPolicy.ordersMarker, BriefInputPolicy.asksMarker].first { line.hasSuffix($0) } ?? ""
        let unmarked = String(line.dropLast(marker.count))
        guard let start = unmarked.range(of: " · \"", options: .backwards) else { return nil }
        let prefix = String(unmarked[..<start.upperBound].dropLast())
        let quoted = String(unmarked[unmarked.index(before: start.upperBound)...])
        guard var body = try? JSONDecoder().decode(String.self, from: Data(quoted.utf8)) else { return nil }
        while !body.isEmpty && (prefix + jsonString(body) + marker + countSuffix).unicodeScalars.count > limit {
            body = scalarPrefix(body, body.unicodeScalars.count - 1)
        }
        let result = prefix + jsonString(body) + marker + countSuffix
        return result.unicodeScalars.count <= limit ? result : nil
    }
}
