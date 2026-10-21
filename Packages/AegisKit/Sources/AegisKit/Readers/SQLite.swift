import CSQLite
import Foundation

/// A SQLite failure. Only the numeric code is retained, never SQL or row content.
public struct SQLiteError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: Int32

    public init(code: Int32) {
        self.code = code
    }

    /// Extended result codes have the same primary code in their low byte.
    public var primaryCode: Int32 {
        code & 0xFF
    }

    public var description: String {
        "SQLite error \(code)"
    }

    /// A lock or busy store can be retried later.
    public var isLocked: Bool {
        primaryCode == SQLITE_BUSY || primaryCode == SQLITE_LOCKED
    }
}

/// A copied SQLite cell; NULL and numeric types remain distinct from text and blobs.
public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// One row, copied before the statement advances. Queries retain only the current row.
public struct SQLiteRow: Sendable, Equatable {
    public let columns: [String]
    public let values: [SQLiteValue]

    public subscript(_ name: String) -> SQLiteValue? {
        guard let index = columns.firstIndex(of: name) else { return nil }
        return values[index]
    }
}

/// A synchronous, scope-bound connection. It is deliberately not Sendable; use it only inside
/// `ReaderBase.openReadOnly` or its reader callback. Retaining it beyond that scope leaves it closed.
public final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(uri: String, flags: Int32) throws {
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(uri, &opened, flags, nil)
        guard code == SQLITE_OK else {
            if let opened {
                sqlite3_close(opened)
            }
            throw SQLiteError(code: code)
        }
        handle = opened
    }

    deinit { close() }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
        }
        handle = nil
    }

    func setBusyTimeout(_ seconds: TimeInterval) throws {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE) }
        let milliseconds = seconds.isFinite ? max(0, min(seconds * 1000, Double(Int32.max))) : 0
        let code = sqlite3_busy_timeout(handle, Int32(milliseconds))
        guard code == SQLITE_OK else { throw SQLiteError(code: code) }
    }

    /// Streams rows in SQLite order, finalizing the statement even if the callback throws.
    /// Bind values with `?` placeholders rather than interpolating collected text into SQL.
    public func query(
        _ sql: String, bindings: [SQLiteValue] = [], onRow: (SQLiteRow) throws -> Void
    ) throws {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE) }
        var prepared: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        defer {
            if let prepared {
                sqlite3_finalize(prepared)
            }
        }
        guard code == SQLITE_OK else { throw SQLiteError(code: code) }
        guard let prepared else { return }
        guard sqlite3_bind_parameter_count(prepared) == bindings.count else { throw SQLiteError(code: SQLITE_RANGE) }
        for (offset, value) in bindings.enumerated() {
            try bind(value, to: prepared, at: Int32(offset + 1))
        }
        let count = sqlite3_column_count(prepared)
        let columns = (0 ..< count).map { String(cString: sqlite3_column_name(prepared, $0)) }
        while true {
            let step = sqlite3_step(prepared)
            if step == SQLITE_DONE {
                return
            }
            guard step == SQLITE_ROW else { throw SQLiteError(code: step) }
            let values = (0 ..< count).map { cell(prepared, at: $0) }
            try onRow(SQLiteRow(columns: columns, values: values))
        }
    }

    /// Executes a statement, discarding rows. The reader connection remains query-only.
    public func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        try query(sql, bindings: bindings) { _ in }
    }

    /// The column names of a table, or an empty list if it does not exist.
    public func columns(_ table: String) throws -> [String] {
        let quoted = table.replacingOccurrences(of: "\"", with: "\"\"")
        var found: [String] = []
        try query("PRAGMA table_info(\"\(quoted)\")") { row in
            if case let .text(name) = row["name"] {
                found.append(name)
            }
        }
        return found
    }

    /// Requires a known schema; errors contain only table and column names.
    @discardableResult
    public func require(_ table: String, columns needed: [String]) throws -> [String] {
        let found = try columns(table)
        guard !found.isEmpty, Set(needed).isSubset(of: Set(found)) else {
            throw UnknownSchemaError(table: table, found: found)
        }
        return found
    }

    private func bind(_ value: SQLiteValue, to statement: OpaquePointer, at index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let code: Int32 = switch value {
        case .null: sqlite3_bind_null(statement, index)
        case let .integer(value): sqlite3_bind_int64(statement, index, value)
        case let .real(value): sqlite3_bind_double(statement, index, value)
        case let .text(value):
            value.utf8CString.withUnsafeBufferPointer {
                sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), transient)
            }
        case let .blob(value):
            if value.isEmpty {
                sqlite3_bind_zeroblob(statement, index, 0)
            } else {
                value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
                }
            }
        }
        guard code == SQLITE_OK else { throw SQLiteError(code: code) }
    }

    private func cell(_ statement: OpaquePointer, at index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard let pointer = sqlite3_column_text(statement, index) else { return .text("") }
            // SQLite text is UTF-8 bytes; replacement characters preserve a readable value for invalid bytes.
            // swiftlint:disable:next optional_data_string_conversion
            return .text(String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard let pointer = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: count))
        default: return .null
        }
    }
}
