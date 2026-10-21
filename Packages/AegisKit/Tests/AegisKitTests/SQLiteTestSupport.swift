import AegisKit
import CSQLite
import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Test-only writer; production exposes no writable-store opening API.
final class SyntheticWriter {
    private var handle: OpaquePointer?

    init(_ path: URL) throws {
        let code = sqlite3_open(path.path, &handle)
        guard code == SQLITE_OK else {
            if let handle {
                sqlite3_close(handle)
            }
            throw SQLiteError(code: code)
        }
    }

    deinit { close() }

    func close() {
        if let handle {
            sqlite3_close(handle)
        }
        handle = nil
    }

    func execute(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw SQLiteError(code: code) }
    }
}

func peakMemoryBytes() throws -> Int64 {
    var usage = rusage()
    #if canImport(Darwin)
        let result = getrusage(RUSAGE_SELF, &usage)
        let scale: Int64 = 1
    #else
        let result = getrusage(Int32(RUSAGE_SELF.rawValue), &usage)
        let scale: Int64 = 1024
    #endif
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return Int64(usage.ru_maxrss) * scale
}
