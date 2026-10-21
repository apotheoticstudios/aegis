import CSQLite
import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// The outcome of reading one source, distinct from individual record problems.
public struct SourceStatus: Sendable, Equatable {
    /// Stable source codes. Contract change #186 adds `formatChanged` and `stale`.
    /// `notFound` represents notInstalled; `permissionDenied` represents permissionMissing,
    /// preserving the existing wire codes instead of introducing aliases.
    public enum Code: String, Codable, Sendable {
        case ok
        case noData = "no_data"
        case notFound = "not_found"
        case permissionDenied = "permission_denied"
        case busy, unreadable
        /// The reader's required tables or columns changed; no records are read.
        case formatChanged = "format_changed"
        /// No successful scan for 30 minutes while another source succeeds.
        case stale
    }

    public var ok: Bool
    public var code: Code
    public var count: Int
    public var problems: Int

    public init(ok: Bool, code: Code, count: Int = 0, problems: Int = 0) {
        self.ok = ok
        self.code = code
        self.count = count
        self.problems = problems
    }
}

/// A store that cannot currently be opened.
public struct StoreUnavailable: Error, Sendable, Equatable {
    public let code: SourceStatus.Code

    public init(code: SourceStatus.Code) {
        self.code = code
    }
}

/// An unsupported table layout. Only schema names are retained, never row content.
public struct UnknownSchemaError: Error, Sendable, Equatable, CustomStringConvertible {
    public let table: String
    public let found: [String]

    public init(table: String, found: [String]) {
        self.table = table
        self.found = found
    }

    public var description: String {
        "unknown schema: table \(table) has columns \(found)"
    }
}

/// A record-level skip or error. Notes should describe the defect, never collected text.
public struct ReadProblem: Codable, Sendable, Equatable {
    public var code: String
    public var source: String
    public var record: String
    public var note: String

    public init(code: String, source: String, record: String, note: String = "") {
        self.code = code
        self.source = source
        self.record = record
        self.note = note
    }
}

/// One item emitted by a reader.
public enum ReadItem: Sendable, Equatable {
    case event(Event)
    case problem(ReadProblem)
}

/// Collected results, or empty arrays with counts when `scan` uses an item callback.
public struct ReadResult: Sendable, Equatable {
    public var status: SourceStatus
    public var events: [Event] = []
    public var problems: [ReadProblem] = []
}

/// Shared, synchronous reader operations; collected content remains data throughout.
public enum ReaderBase {
    /// Maximum attempts to obtain a stable private database/WAL copy.
    public static let copyAttempts = 3
    /// A future timestamp is flagged only beyond this allowance.
    public static let clockSkewAllowance: TimeInterval = 10 * 60

    /// A reader streams items by calling `emit`. `now` and `since` are passed through unchanged.
    public typealias Reader = (
        SQLiteConnection, _ now: Date, _ since: Date?, _ emit: (ReadItem) throws -> Void
    ) throws -> Void

    /// Opens with `mode=ro` and a busy timeout; never uses SQLite's immutable mode.
    /// WAL stores are read from a private copy including their log: even a mode=ro connection can
    /// modify an existing SHM file. Missing sidecars are recovered only in that private directory.
    public static func openReadOnly<Result>(
        _ path: URL, busyTimeout: TimeInterval = 5, body: (SQLiteConnection) throws -> Result
    ) throws -> Result {
        try withConnection(path, busyTimeout: busyTimeout, access: StoreAccess(), body: body)
    }

    /// Streams a source, translating store failures to status codes. Unknown schemas and reader
    /// errors propagate. With `onItem`, neither events nor problems accumulate in the result.
    public static func scan(
        _ path: URL, reader: Reader, now: Date = Date(), since: Date? = nil,
        busyTimeout: TimeInterval = 5, onItem: ((ReadItem) throws -> Void)? = nil
    ) throws -> ReadResult {
        try scan(
            path,
            reader: reader,
            now: now,
            since: since,
            busyTimeout: busyTimeout,
            onItem: onItem,
            access: StoreAccess()
        )
    }

    /// Injectable file/connection operations keep race and permission tests deterministic.
    static func scan(
        _ path: URL, reader: Reader, now: Date = Date(), since: Date? = nil,
        busyTimeout: TimeInterval = 5, onItem: ((ReadItem) throws -> Void)? = nil, access: StoreAccess
    ) throws -> ReadResult {
        var result = ReadResult(status: SourceStatus(ok: true, code: .ok))
        do {
            try withConnection(path, busyTimeout: busyTimeout, access: access) { connection in
                try reader(connection, now, since) { item in
                    switch item {
                    case .event: result.status.count += 1
                    case .problem: result.status.problems += 1
                    }
                    if let onItem {
                        try onItem(item)
                    } else {
                        switch item {
                        case let .event(event): result.events.append(event)
                        case let .problem(problem): result.problems.append(problem)
                        }
                    }
                }
            }
        } catch let error as StoreUnavailable {
            result.status.ok = false
            result.status.code = error.code
        } catch let error as SQLiteError {
            result.status.ok = false
            result.status.code = try statusCode(for: error)
        }
        // This is a scalar count; streaming deliberately keeps the event array empty.
        // swiftlint:disable:next empty_count
        if result.status.ok, result.status.count == 0 {
            result.status.code = .noData
        }
        return result
    }

    /// Translate only fingerprint failures; item callback errors still propagate unchanged.
    static func supportedSchema<Result>(_ check: () throws -> Result) throws -> Result {
        do {
            return try check()
        } catch is UnknownSchemaError {
            throw StoreUnavailable(code: .formatChanged)
        }
    }

    private static func statusCode(for error: SQLiteError) throws -> SourceStatus.Code {
        if error.isLocked {
            return .busy
        }
        switch error.primaryCode {
        case SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_AUTH, SQLITE_READONLY: return .permissionDenied
        case SQLITE_ERROR, SQLITE_INTERNAL, SQLITE_ABORT, SQLITE_MISUSE, SQLITE_RANGE,
             SQLITE_SCHEMA, SQLITE_INTERRUPT, SQLITE_NOMEM, SQLITE_IOERR, SQLITE_FULL:
            // Python's OperationalError is rethrown unless it means locked/busy/unable-to-open.
            throw error
        default: return .unreadable
        }
    }

    private static func withConnection<Result>(
        _ path: URL, busyTimeout: TimeInterval, access: StoreAccess, body: (SQLiteConnection) throws -> Result
    ) throws -> Result {
        // Resolve the main store before finding its WAL, rather than copying a symlink into a writable snapshot.
        let path = path.resolvingSymlinksInPath()
        let header = try access.header(path)
        let usesWAL = header.count == 20 && (header[18] == 2 || header[19] == 2)
        var temporary: URL?
        defer {
            if let temporary {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        let target: URL
        let flags: Int32
        let mode: String
        if usesWAL {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-reader-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            temporary = folder
            target = try privateCopy(path, into: folder, access: access)
            // SQLite needs writable private sidecars to recover a WAL whose shared-memory file is absent.
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI
            mode = "rw"
        } else {
            target = path
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            mode = "ro"
        }
        let connection: SQLiteConnection
        do {
            connection = try access.connect(target.standardizedFileURL.absoluteString + "?mode=" + mode, flags)
        } catch let error as SQLiteError where error.primaryCode == SQLITE_CANTOPEN {
            throw StoreUnavailable(code: .permissionDenied)
        }
        defer { connection.close() }
        try connection.setBusyTimeout(busyTimeout)
        try connection.execute("PRAGMA query_only = ON")
        return try body(connection)
    }

    private static func privateCopy(_ path: URL, into folder: URL, access: StoreAccess) throws -> URL {
        let target = folder.appendingPathComponent(path.lastPathComponent)
        let wal = URL(fileURLWithPath: path.path + "-wal")
        let walCopy = URL(fileURLWithPath: target.path + "-wal")
        for _ in 0 ..< copyAttempts {
            let before = try [stamp(path), stamp(wal)]
            guard before[0] != nil else { throw StoreUnavailable(code: .notFound) }
            try access.copy(path, target)
            if before[1] != nil {
                try access.copy(wal, walCopy)
            } else if FileManager.default.fileExists(atPath: walCopy.path) {
                try FileManager.default.removeItem(at: walCopy)
            }
            if try [stamp(path), stamp(wal)] == before {
                return target
            }
        }
        throw SQLiteError(code: SQLITE_BUSY)
    }
}

/// Internal injection points for tests, with production defaults and no shared mutable state.
struct StoreAccess {
    var header: (URL) throws -> [UInt8] = readHeader
    var copy: (URL, URL) throws -> Void = copyFile
    var connect: (String, Int32) throws -> SQLiteConnection = { try SQLiteConnection(uri: $0, flags: $1) }
}

private struct FileStamp: Equatable {
    let size: Int64
    let seconds: Int64
    let nanoseconds: Int64
}

private func stamp(_ path: URL) throws -> FileStamp? {
    var info = stat()
    let result = path.path.withCString { stat($0, &info) }
    guard result == 0 else {
        if errno == ENOENT {
            return nil
        }
        throw fileError(errno)
    }
    #if canImport(Darwin)
        let modified = info.st_mtimespec
    #else
        let modified = info.st_mtim
    #endif
    return FileStamp(size: Int64(info.st_size), seconds: Int64(modified.tv_sec), nanoseconds: Int64(modified.tv_nsec))
}

private func readHeader(_ path: URL) throws -> [UInt8] {
    let descriptor = path.path.withCString { open($0, O_RDONLY) }
    guard descriptor >= 0 else { throw fileError(errno) }
    defer { close(descriptor) }
    var bytes = [UInt8](repeating: 0, count: 20)
    var count = 0
    while count < bytes.count {
        let readCount = bytes.withUnsafeMutableBytes {
            read(descriptor, $0.baseAddress?.advanced(by: count), $0.count - count)
        }
        if readCount == 0 {
            break
        }
        if readCount < 0 {
            if errno == EINTR {
                continue
            }
            throw fileError(errno)
        }
        count += readCount
    }
    return Array(bytes.prefix(count))
}

private func fileError(_ code: Int32) -> any Error {
    switch code {
    case ENOENT: StoreUnavailable(code: .notFound)
    case EACCES, EPERM: StoreUnavailable(code: .permissionDenied)
    default: NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

private func copyFile(_ source: URL, _ target: URL) throws {
    do {
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source.resolvingSymlinksInPath(), to: target)
        // The source may itself be mode 0444. The private copy must allow WAL recovery.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    } catch {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            if error.code == NSFileReadNoSuchFileError {
                throw StoreUnavailable(code: .notFound)
            }
            if [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) {
                throw StoreUnavailable(code: .permissionDenied)
            }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            throw fileError(Int32(underlying.code))
        }
        if error.domain == NSPOSIXErrorDomain {
            throw fileError(Int32(error.code))
        }
        throw error
    }
}
