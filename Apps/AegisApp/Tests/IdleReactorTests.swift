@testable import Aegis
import AppKit
import XCTest

@MainActor
final class IdleReactorTests: XCTestCase {
    func testReactorRunsOnlyForVisibleActiveModes() {
        let view = ReactorSceneView(size: 100)
        let window = ReactorTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless, backing: .buffered, defer: true
        )
        view.configure(mode: .speaking, theme: .arc, held: false)
        XCTAssertFalse(view.rendersContinuously)
        window.contentView = view
        XCTAssertTrue(view.rendersContinuously)
        XCTAssertTrue(view.isPlaying)

        view.configure(mode: .idle, theme: .arc, held: false)
        XCTAssertFalse(view.rendersContinuously)
        XCTAssertFalse(view.isPlaying)
        view.configure(mode: .listening, theme: .arc, held: true)
        XCTAssertFalse(view.rendersContinuously)
        view.configure(mode: .listening, theme: .arc, held: false)
        XCTAssertTrue(view.rendersContinuously)

        window.visibleForTest = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertFalse(view.rendersContinuously)
        XCTAssertFalse(view.isPlaying)
        window.visibleForTest = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertTrue(view.rendersContinuously)
        window.contentView = nil
        XCTAssertFalse(view.rendersContinuously)
    }
}

private final class ReactorTestWindow: NSWindow {
    var visibleForTest = true
    override var occlusionState: OcclusionState {
        visibleForTest ? .visible : []
    }
}
