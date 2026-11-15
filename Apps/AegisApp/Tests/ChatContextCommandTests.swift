@testable import Aegis
import AegisKit
import XCTest

/// The owner's report (#203), exchange by exchange, through the panel's command path. Nothing runs a real shortcut
/// (they never run under tests) and the owner's real shortcuts are never read.
@MainActor
final class ChatContextCommandTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chat-context-\(UUID().uuidString)")
    private let core = CountingCore()

    override func setUp() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        ActionPresence.shared.pending = nil
        ActionPresence.shared.shortcuts = (["Work", "ExampleDev", "Backup"], Date())
        HUDPresence.shared.open = true
    }

    override func tearDown() async throws {
        ActionPresence.shared.pending = nil
        ActionPresence.shared.shortcuts = nil
        ActionPresence.shared.context = nil
        ActionPresence.shared.chattedSince = false
        HUDPresence.shared.open = false
        try? FileManager.default.removeItem(at: folder)
    }

    private var file: ActionLogFile {
        get throws { try ActionLogFile(url: folder.appendingPathComponent("audit.json")) }
    }

    private func model() throws -> PanelModel {
        try PanelModel(service: core, actions: ActionLog(persistence: file))
    }

    func testOpenThePanelGetsAFixedAnswer() async throws {
        let answer = try await model().worldAnswer("Open the panel")
        XCTAssertEqual(answer?.text, "The panel's already open.")
        XCTAssertEqual(core.requests, [], "the model never narrates it")
        XCTAssertEqual(try file.load().count, 0)
    }

    func testWhatIsSaidBeforeARequestDoesNotHideIt() async throws {
        let model = try model()
        await model.submit("Sweet. Open the panel")
        guard case let .answered(question, answer) = model.askState else { return XCTFail("no answer") }
        XCTAssertEqual(question, "Sweet. Open the panel", "shown as the owner said it")
        XCTAssertEqual(answer.text, "The panel's already open.")
        XCTAssertFalse(core.requests.contains("ask"), "never handed to the model")
    }

    func testARequestNothingCouldDoIsAskedInstead() async throws {
        let answer = try await model().actionAnswer("crank it up and make it brighter")
        XCTAssertNil(answer, "no “I can't do any of that”: it goes on as a question")
    }

    func testAgainAfterAFixedAnswerIsNotTheCommandBefore() async throws {
        let model = try model()
        _ = await model.worldAnswer("run the Work shortcut")
        _ = await model.worldAnswer("Open the panel")
        let again = await model.followUpAnswer("again", origin: .ownerTyped)
        XCTAssertNil(again, "Work doesn't run again")
    }

    func testAMisheardShortcutIsOfferedAndTheCorrectionRunsIt() async throws {
        let model = try model()
        let misheard = await model.worldAnswer("Run the Exampel's Dev shortcut.")
        XCTAssertEqual(misheard?.text, "Run the shortcut “ExampleDev”? Say yes, or press Run.", "offered, never run as heard")
        XCTAssertEqual(ActionPresence.shared.pending?.command, .runShortcut(name: "ExampleDev"))
        let corrected = await model.worldAnswer("I mean, Example Dev.")
        XCTAssertEqual(corrected?.text, "Shortcuts don't run under tests.", "the corrected name runs at once, as said")
        XCTAssertNil(ActionPresence.shared.pending, "the offer gave way to the correction")
        XCTAssertEqual(try file.load().map(\.outcomeCode), [.proposed, .awaitingConfirmation, .cancelled, .proposed, .failed])
        XCTAssertEqual(core.requests, [])
    }

    func testANameWithASpaceIsTheShortcut() async throws {
        let answer = try await model().worldAnswer("run the Example Dev shortcut")
        XCTAssertEqual(answer?.text, "Shortcuts don't run under tests.")
        XCTAssertNil(ActionPresence.shared.pending)
    }

    func testAnUnknownNameCanBeCorrected() async throws {
        let model = try model()
        let unknown = await model.worldAnswer("run the Synthetic shortcut")
        XCTAssertEqual(unknown?.text, "You don't have a shortcut called “Synthetic”.")
        // "No, Backup", not "no, Work": a lone workspace name switches AegisShell's workspace first.
        let corrected = await model.worldAnswer("no, Backup")
        XCTAssertEqual(corrected?.text, "Shortcuts don't run under tests.")
    }

    func testCancelWithNothingWaitingSaysSo() async throws {
        let answer = try await model().worldAnswer("Cancel")
        XCTAssertEqual(answer?.text, "There's nothing to cancel.")
        XCTAssertEqual(core.requests, [], "no model reply")
        XCTAssertEqual(try file.load().count, 0, "nothing was asked of the action system")
    }

    func testCancelStillCancelsAWaitingCard() async throws {
        let model = try model()
        _ = await model.worldAnswer("Run the Exampel's Dev shortcut.")
        let answer = await model.worldAnswer("Cancel")
        XCTAssertEqual(answer?.text, "Cancelled.")
        XCTAssertNil(ActionPresence.shared.pending)
        XCTAssertEqual(try file.load().last?.outcomeCode, .cancelled)
    }

    func testAfterAChatACorrectionIsTheChats() async throws {
        let model = try model()
        _ = await model.worldAnswer("run the Synthetic shortcut")
        ActionPresence.shared.chattedSince = true
        let answer = await model.followUpAnswer("I mean, Work", origin: .ownerTyped)
        XCTAssertNil(answer)
    }
}

/// A AegisCore stand-in that answers nothing and records what it was asked.
private final class CountingCore: CoreService, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []

    var requests: [String] {
        lock.withLock { asked }
    }

    func handle(_ request: CoreRequest) async -> CoreResponse {
        lock.withLock { asked.append(String(describing: request).prefix { $0 != "(" }.description) }
        return .refused(code: "busy")
    }
}
