@testable import AegisKit
import XCTest

final class ShellCommandTests: XCTestCase {
    func testOwnersWordsEngageAndLeave() {
        for text in [
            "Engage",
            "Engage.",
            "Aegis, engage.",
            "Hey Aegis engage",
            "engage AegisShell",
            "Start the shell",
            "turn on Aegis Mode",
            "Jarvis, engage",
        ] {
            XCTAssertEqual(ShellCommand.parse(text), .engage, text)
        }
        for text in ["Stand down", "Aegis, stand down", "disengage", "Exit AegisShell", "close the shell", "turn off aegis mode please"] {
            XCTAssertEqual(ShellCommand.parse(text), .disengage, text)
        }
        let workspaces: [(String, ShellWorkspace)] = [
            ("Focus mode", .focus), ("Aegis, focus mode", .focus), ("switch to evening", .evening), ("movie time", .movie),
            ("Back to work", .work), ("go to the film workspace", .movie), ("start focus", .focus),
        ]
        for (text, workspace) in workspaces {
            XCTAssertEqual(ShellCommand.parse(text), .workspace(workspace), text)
        }
        for text in ["what's on this evening", "focus on Xcode", "I need to focus", "work on the plan"] {
            XCTAssertNil(ShellCommand.parse(text), text)
        }
        for text in ["engage with Sam's email", "open Safari", "exit", "close it", "start", "what does stand down mean"] {
            XCTAssertNil(ShellCommand.parse(text), text)
        }
    }
}
