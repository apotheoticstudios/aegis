@testable import Aegis
import XCTest

/// Presentation-only checks: no web view, World server, network or owner data.
final class WorldPresenceTests: XCTestCase {
    @MainActor func testShowingAndReturningNotifyOnlyOnTransitions() {
        let world = WorldPresence()
        var changes: [Bool] = []
        world.presentationChanged = { changes.append($0) }
        XCTAssertFalse(world.inPanel)
        world.show()
        world.show()
        XCTAssertTrue(world.inPanel)
        XCTAssertEqual(changes, [true], "reopening must not save the expanded frame as the HUD frame")
        world.close()
        world.close()
        XCTAssertFalse(world.inPanel)
        XCTAssertEqual(changes, [true, false])
        world.show()
        XCTAssertTrue(world.inPanel)
        XCTAssertEqual(changes, [true, false, true])
    }

    @MainActor func testCloseCommandReturnsToHudWithoutStartingTheGlobe() async {
        let world = WorldPresence.shared
        world.show()
        XCTAssertTrue(WorldWindow.shared.isOpen)
        var requestedSchedule = false
        let answer = await WorldWindow.shared.run(.close) {
            requestedSchedule = true
            return []
        }
        XCTAssertEqual(answer, "World view closed.")
        XCTAssertFalse(world.inPanel)
        XCTAssertFalse(WorldWindow.shared.isOpen)
        XCTAssertFalse(requestedSchedule)
    }
}
