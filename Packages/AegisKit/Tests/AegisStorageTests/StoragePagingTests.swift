import AegisKit
@testable import AegisStorage
import Foundation
import XCTest
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@MainActor
final class StoragePagingTests: StorageTestCase {
    func testFiftyThousandEventsInBoundedBatchesAndPages() async throws {
        let store = try open()
        let before = try peakMemoryBytes()
        let count = 50000
        for base in stride(from: 0, to: count, by: 250) {
            let rows = (base ..< base + 250).map { event($0, time: Double($0), body: String(repeating: "x", count: 2048)) }
            try await store.ingest(batch(rows, scan: Double(base)))
        }
        let bounded = try await store.events(from: epoch, to: epoch.addingTimeInterval(Double(count)))
        XCTAssertEqual(bounded.count, GRDBEventStore.pageSize)
        var cursor: EventCursor?
        var seen = 0
        var previousTime = epoch.addingTimeInterval(-1)
        while true {
            let page = try await store.events(from: epoch, to: epoch.addingTimeInterval(Double(count)), after: cursor, limit: 250)
            XCTAssertLessThanOrEqual(page.count, 250)
            guard let last = page.last else { break }
            for row in page {
                XCTAssertGreaterThan(row.eventTime, previousTime)
                previousTime = row.eventTime
            }
            seen += page.count
            cursor = EventCursor(after: last)
        }
        XCTAssertEqual(seen, count)
        // The payload alone is >100 MB. Loading all records would exceed this growth allowance.
        let growth = try peakMemoryBytes() - before
        XCTAssertLessThan(growth, 80 * 1024 * 1024)
    }

    func testInvalidLimitsAndHorizon() async throws {
        let store = try open()
        for limit in [0, -1, GRDBEventStore.pageSize + 1] {
            do {
                _ = try await store.events(from: epoch, to: epoch, after: nil, limit: limit)
                XCTFail("invalid limit")
            } catch { XCTAssertEqual(error as? StorageError, .invalidLimit) }
        }
        do {
            _ = try await store.maintain(horizon: -1)
            XCTFail("invalid horizon")
        } catch { XCTAssertEqual(error as? StorageError, .invalidHorizon) }
    }

    private func peakMemoryBytes() throws -> Int64 {
        var usage = rusage()
        #if canImport(Darwin)
            let result = getrusage(RUSAGE_SELF, &usage)
            let bytes = Int64(usage.ru_maxrss)
        #else
            let result = getrusage(Int32(RUSAGE_SELF.rawValue), &usage)
            let bytes = Int64(usage.ru_maxrss) * 1024
        #endif
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return bytes
    }
}
