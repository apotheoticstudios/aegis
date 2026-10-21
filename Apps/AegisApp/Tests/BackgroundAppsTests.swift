@testable import Aegis
import AppKit
import XCTest

@MainActor
final class BackgroundAppsTests: XCTestCase {
    func testMailLaunchIsHiddenAndRetriesAfterFailure() async {
        var attempts = 0
        let mail = MailKeeper(isRunning: { false }, applicationURL: { URL(fileURLWithPath: "/synthetic/Mail.app") }, launch: { _, config in
            XCTAssertFalse(config.activates)
            XCTAssertTrue(config.hides)
            XCTAssertFalse(config.addsToRecentItems)
            attempts += 1
            if attempts == 1 {
                throw CocoaError(.executableNotLoadable)
            }
        })
        await mail.ensureRunning()
        await mail.ensureRunning()
        XCTAssertEqual(attempts, 2)
    }

    func testMailLeavesExistingWindowsAloneAndDoesNotDuplicateLaunches() async {
        var running = true
        var attempts = 0
        let gate = AsyncGate()
        let mail = MailKeeper(isRunning: { running }, applicationURL: { URL(fileURLWithPath: "/synthetic/Mail.app") }, launch: { _, _ in
            attempts += 1
            await gate.wait()
        })
        await mail.ensureRunning()
        XCTAssertEqual(attempts, 0)
        running = false
        let first = Task { await mail.ensureRunning() }
        while attempts == 0 {
            await Task.yield()
        }
        await mail.ensureRunning()
        XCTAssertEqual(attempts, 1)
        await gate.open()
        await first.value
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool {
        continuation != nil
    }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume(); continuation = nil
    }
}
