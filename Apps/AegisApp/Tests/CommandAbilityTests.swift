@testable import Aegis
import AegisKit
import XCTest

/// General commands in the panel (ADR-0031). Only paths that stop at a card or a refusal are run here: nothing opens
/// a browser or runs a shortcut, and the owner's real shortcuts are never read.
@MainActor
final class CommandAbilityTests: XCTestCase {
    private var folder: URL!
    private var file: ActionLogFile!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("command-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        file = try ActionLogFile(url: folder.appendingPathComponent("audit.json"))
        ActionPresence.shared.pending = nil
        ActionPresence.shared.shortcuts = (["Work", "Pay Rent"], Date())
    }

    override func tearDown() async throws {
        ActionPresence.shared.pending = nil
        ActionPresence.shared.shortcuts = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func model(_ step: CommandStep? = nil, _ core: PickingCore? = nil) -> PanelModel {
        PanelModel(service: core ?? PickingCore(step: step), actions: ActionLog(persistence: file))
    }

    func testAWebsiteTheModelWorkedOutAsksFirst() async throws {
        let model = model(CommandStep(ability: .website, value: "https://www.bom.gov.au"))
        let answer = await model.commandPlanAnswer("open the weather bureau site")
        XCTAssertEqual(answer?.text, "Open www.bom.gov.au? Say yes, or press Open.")
        let pending = try XCTUnwrap(ActionPresence.shared.pending)
        XCTAssertEqual(pending.button, "Open")
        XCTAssertTrue(pending.guessed)
        let entries = try file.load()
        XCTAssertEqual(entries.map(\.outcomeCode), [.proposed, .awaitingConfirmation])
        XCTAssertEqual(entries.map(\.domain), [.web, .web])
        XCTAssertEqual(entries.first?.decision.tier, .confirm)
        XCTAssertFalse(try String(contentsOf: file.url, encoding: .utf8).contains("bom"))
        await model.cancelAction()
        XCTAssertEqual(try file.load().last?.outcomeCode, .cancelled)
        XCTAssertEqual(try file.load().last?.decision.tier, .confirm)
    }

    func testAShortcutTheModelPickedAsksFirst() async {
        let answer = await model(CommandStep(ability: .shortcut, value: "Work")).commandPlanAnswer("start my work day")
        XCTAssertEqual(answer?.text, "Run the shortcut “Work”? Say yes, or press Run.")
        XCTAssertEqual(ActionPresence.shared.pending?.command, .runShortcut(name: "Work"))
    }

    func testNeverListShortcutsAndUnknownNamesDoNothing() async throws {
        let model = model()
        let never = await model.actionAnswer("run the pay rent shortcut")
        XCTAssertEqual(never?.text.contains("never-list"), true)
        XCTAssertNil(ActionPresence.shared.pending)
        let entries = try file.load()
        XCTAssertEqual(entries.map(\.outcomeCode), [.proposed, .rejected])
        XCTAssertEqual(entries.first?.decision.reasonCodes, [.payment])
        let unknown = await model.actionAnswer("run the Synthetic shortcut")
        XCTAssertEqual(unknown?.text, "You don't have a shortcut called “Synthetic”.")
        XCTAssertEqual(try file.load().count, 2)
    }

    func testOnlyCommandsAskTheModel() async {
        let core = PickingCore(step: CommandStep(ability: .shortcut, value: "Work"))
        let model = model(nil, core)
        let question = await model.commandPlanAnswer("what's on today")
        let memory = await model.commandPlanAnswer("start learning about me again")
        XCTAssertNil(question)
        XCTAssertNil(memory)
        XCTAssertEqual(core.asked, [])
        _ = await model.commandPlanAnswer("turn the lights on")
        XCTAssertEqual(core.asked, ["turn the lights on"])
        XCTAssertEqual(core.shortcuts, ["Work", "Pay Rent"])
    }
}

/// A AegisCore stand-in whose model picks `step` for every command.
private final class PickingCore: CoreService, @unchecked Sendable {
    private let lock = NSLock()
    private let step: CommandStep?
    private var questions: [String] = []
    private var names: [String] = []

    init(step: CommandStep?) {
        self.step = step
    }

    var asked: [String] {
        lock.withLock { questions }
    }

    var shortcuts: [String] {
        lock.withLock { names }
    }

    func handle(_ request: CoreRequest) async -> CoreResponse {
        guard case let .commandPlan(question, shortcuts) = request else { return .refused(code: "busy") }
        lock.withLock {
            questions.append(question)
            names = shortcuts
        }
        return .commandPlan(step)
    }
}
