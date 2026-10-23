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

    // MARK: - Files and the app catalogue (#43)

    func testCatalogueStepsTheModelPickedAskFirst() async throws {
        let cases: [(CommandStep, String)] = [
            (CommandStep(ability: .note, value: "Groceries"), "Make a note called “Groceries”? Say yes, or press Add."),
            (CommandStep(ability: .pause, value: ""), "Pause the music? Say yes, or press Run."),
            (CommandStep(ability: .playlist, value: "Running"), "Play the playlist “Running”? Say yes, or press Run."),
            (
                CommandStep(ability: .tab, value: "https://www.bom.gov.au"),
                "Open www.bom.gov.au in a new Safari tab? Say yes, or press Open."
            ),
        ]
        for (step, card) in cases {
            ActionPresence.shared.pending = nil
            let answer = await model(step).commandPlanAnswer("play something")
            XCTAssertEqual(answer?.text, card)
            let pending = try XCTUnwrap(ActionPresence.shared.pending)
            XCTAssertTrue(pending.guessed)
            XCTAssertEqual(pending.request.payload.domain, .app)
        }
        let entries = try file.load()
        XCTAssertEqual(entries.map(\.decision.tier), Array(repeating: .confirm, count: 8))
        let log = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertFalse(log.contains("Groceries") || log.contains("Running") || log.contains("bom"))
    }

    func testAFolderTheModelPickedAsksFirst() async throws {
        let open = await model(CommandStep(ability: .file, value: "Downloads folder")).commandPlanAnswer("open where my downloads go")
        XCTAssertEqual(open?.text, "Open “Downloads”? Say yes, or press Open.")
        XCTAssertEqual(ActionPresence.shared.pending?.command, .openFile(path: NSHomeDirectory() + "/Downloads"))
        let reveal = await model(CommandStep(ability: .reveal, value: "my Desktop")).commandPlanAnswer("reveal my desktop")
        XCTAssertEqual(reveal?.text, "Show “Desktop” in Finder? Say yes, or press Show.")
        let entries = try file.load()
        XCTAssertEqual(entries.map(\.domain), [.file, .file, .app, .app])
        XCTAssertFalse(try String(contentsOf: file.url, encoding: .utf8).contains("Downloads"))
    }

    func testFilesAreNeverSearchedUnderTests() async throws {
        ActionPresence.shared.pending = nil
        let guessed = await model(CommandStep(ability: .file, value: "Budget spreadsheet")).commandPlanAnswer("open my budget")
        XCTAssertNil(guessed)
        let named = await model().actionAnswer("open the Synthetic spreadsheet")
        XCTAssertEqual(named?.text, "I couldn't find “Synthetic” in your home folder.")
        XCTAssertNil(ActionPresence.shared.pending)
        XCTAssertEqual(try file.load().count, 0)
    }

    func testCatalogueScriptsTakeArgumentsOnlyAsArgv() {
        let links: Set<AppAutomation> = [.finderReveal, .mapsDirections, .mapsSearch, .settingsPage]
        XCTAssertEqual(Set(PanelModel.scripts.keys), Set(AppAutomation.allCases).subtracting(links))
        for (entry, script) in PanelModel.scripts {
            let takesArgument = [AppAutomation.musicPlaylist, .notesNewNote, .safariNewTab, .volumeSet].contains(entry)
            XCTAssertEqual(script.contains("on run argv"), takesArgument, entry.rawValue)
            XCTAssertEqual(script.contains("item 1 of argv"), takesArgument, entry.rawValue)
            XCTAssertFalse(script.contains("do shell script"), entry.rawValue)
        }
    }
}

extension CommandAbilityTests {
    /// Maps and Settings pages open by link, with the owner's words encoded as one value (#45).
    func testMapsAndSettingsLinksEncodeTheOwnersWords() {
        XCTAssertEqual(
            PanelModel.link(.mapsDirections, "Brisbane Airport & daddr=x")?.absoluteString,
            "maps://?daddr=Brisbane%20Airport%20%26%20daddr%3Dx"
        )
        XCTAssertEqual(PanelModel.link(.mapsSearch, "pharmacy")?.absoluteString, "maps://?q=pharmacy")
        XCTAssertEqual(
            PanelModel.link(.settingsPage, "wifi")?.absoluteString,
            "x-apple.systempreferences:com.apple.wifi-settings-extension"
        )
        XCTAssertNil(PanelModel.link(.settingsPage, "com.apple.anything"))
        XCTAssertNil(PanelModel.link(.volumeSet, "30"))
    }

    func testSystemStepsTheModelPickedAskFirst() async throws {
        let cases: [(CommandStep, String)] = [
            (CommandStep(ability: .volume, value: "30"), "Set the volume to 30%? Say yes, or press Run."),
            (CommandStep(ability: .dark, value: ""), "Turn on dark mode? Say yes, or press Run."),
            (CommandStep(ability: .settings, value: "bluetooth"), "Open Bluetooth settings? Say yes, or press Open."),
            (CommandStep(ability: .directions, value: "the airport"), "Get directions to “the airport” in Maps? Say yes, or press Open."),
        ]
        for (step, card) in cases {
            ActionPresence.shared.pending = nil
            let answer = await model(step).commandPlanAnswer("set things up")
            XCTAssertEqual(answer?.text, card)
            XCTAssertEqual(ActionPresence.shared.pending?.guessed, true)
        }
        XCTAssertEqual(try file.load().map(\.decision.tier), Array(repeating: .confirm, count: 8))
    }
}

/// Plans (#47): only the card and its logging run here; nothing in a plan runs on the owner's Mac.
extension CommandAbilityTests {
    func testAPlanIsShownBeforeAnythingRuns() async throws {
        let model = model()
        let answer = await model.actionAnswer("pause the music and open Wi-Fi settings")
        XCTAssertEqual(answer?.text, "Here's the plan: pause the music, then open Wi-Fi settings. Say yes, or press Go.")
        let pending = try XCTUnwrap(ActionPresence.shared.pending)
        XCTAssertEqual(pending.button, "Go")
        XCTAssertEqual(pending.plan.map(\.command), [.automate(.musicPause, argument: ""), .automate(.settingsPage, argument: "wifi")])
        XCTAssertEqual(try file.load().map(\.outcomeCode), [.proposed, .proposed, .awaitingConfirmation, .awaitingConfirmation])
        await model.cancelAction()
        XCTAssertNil(ActionPresence.shared.pending)
        XCTAssertEqual(try file.load().suffix(2).map(\.outcomeCode), [.cancelled, .cancelled])
        XCTAssertEqual(try Set(file.load().map(\.requestID)).count, 2)
    }

    func testAPlanLeavesOutWhatItCannotDo() async throws {
        let answer = await model().actionAnswer("run the Pay Rent shortcut and mute")
        XCTAssertEqual(
            answer?.text,
            "Here's the plan: mute the sound. I'll leave out “run the Pay Rent shortcut”: I can't do that. Say yes, or press Go."
        )
        XCTAssertEqual(ActionPresence.shared.pending?.plan.count, 1)
        let entries = try file.load()
        XCTAssertEqual(entries.map(\.outcomeCode), [.proposed, .rejected, .proposed, .awaitingConfirmation])
        XCTAssertEqual(entries.first?.decision.reasonCodes, [.payment])
    }

    func testAPlanAsksTheModelOnlyForPartsItCannotWorkOut() async throws {
        let core = PickingCore(step: CommandStep(ability: .shortcut, value: "Work"))
        let answer = await model(nil, core).actionAnswer("start my work day and mute")
        XCTAssertEqual(answer?.text, "Here's the plan: run the shortcut “Work”, then mute the sound. Say yes, or press Go.")
        XCTAssertEqual(core.asked, ["start my work day"])
        XCTAssertEqual(ActionPresence.shared.pending?.plan.map(\.guessed), [true, false])
        XCTAssertEqual(try file.load().first?.decision.tier, .confirm)
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
