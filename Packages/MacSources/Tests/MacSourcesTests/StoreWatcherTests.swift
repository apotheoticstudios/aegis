import Foundation
@testable import MacSources
import XCTest

/// The watcher on a temporary store (never a real one): writes, a replaced WAL, and coalescing.
final class StoreWatcherTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("main".utf8).write(to: folder.appendingPathComponent("db"))
        try Data().write(to: folder.appendingPathComponent("db-wal"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int {
            lock.withLock { value }
        }

        func add() {
            lock.withLock { value += 1 }
        }
    }

    private func append(_ name: String) throws {
        let handle = try FileHandle(forWritingTo: folder.appendingPathComponent(name))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("x".utf8))
        try handle.close()
    }

    private func waitUntil(_ condition: () -> Bool, seconds: TimeInterval = 3) {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testWriteToTheLogCallsOnceAfterTheDelay() throws {
        let calls = Counter()
        let watcher = StoreWatcher(store: folder.appendingPathComponent("db"), delay: 0.1, minimumGap: 0) { calls.add() }
        watcher.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        for _ in 0 ..< 20 {
            try append("db-wal")
        }
        waitUntil { calls.count >= 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(calls.count, 1, "a burst of writes is one call")
        watcher.stop()
    }

    func testReplacedLogIsWatchedAgain() throws {
        let calls = Counter()
        let watcher = StoreWatcher(store: folder.appendingPathComponent("db"), delay: 0.05, minimumGap: 0) { calls.add() }
        watcher.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("db-wal"))
        waitUntil { calls.count >= 1 }
        try Data().write(to: folder.appendingPathComponent("db-wal"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let before = calls.count
        try append("db-wal")
        waitUntil { calls.count > before }
        XCTAssertGreaterThan(calls.count, before, "the new log is watched")
        watcher.stop()
    }

    func testMinimumGapSpacesCalls() throws {
        let calls = Counter()
        let watcher = StoreWatcher(store: folder.appendingPathComponent("db"), delay: 0.05, minimumGap: 0.6) { calls.add() }
        watcher.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try append("db")
        waitUntil { calls.count >= 1 }
        try append("db")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(calls.count, 1, "the second change waits for the gap")
        waitUntil { calls.count >= 2 }
        XCTAssertEqual(calls.count, 2)
        watcher.stop()
    }

    func testRearmPicksUpAFolderCreatedLater() throws {
        let calls = Counter()
        let later = folder.appendingPathComponent("later")
        let watcher = StoreWatcher(store: later.appendingPathComponent("db"), delay: 0.05, minimumGap: 0) { calls.add() }
        watcher.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        try Data("main".utf8).write(to: later.appendingPathComponent("db"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(calls.count, 0, "nothing watched the missing folder")
        watcher.rearm()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let handle = try FileHandle(forWritingTo: later.appendingPathComponent("db"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("x".utf8))
        try handle.close()
        waitUntil { calls.count >= 1 }
        XCTAssertEqual(calls.count, 1)
        watcher.stop()
    }

    func testQuietFilesNeverCall() {
        let calls = Counter()
        let watcher = StoreWatcher(store: folder.appendingPathComponent("db"), delay: 0.05, minimumGap: 0) { calls.add() }
        watcher.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(calls.count, 0)
        watcher.stop()
    }
}
