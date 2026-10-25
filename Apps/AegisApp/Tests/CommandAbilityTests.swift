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
        HUDPresence.shared.open = true
    }

    override func tearDown() async throws {
        ActionPresence.shared.pending = nil
        ActionPresence.shared.shortcuts = nil
        ActionPresence.shared.context = nil
        ActionPresence.shared.chattedSince = false
        ActionPresence.shared.planRest = nil
        HUDPresence.shared.open = false
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

/// Follow-ups (#49): only cards and refusals run here, never an app, file or script on the owner's Mac.
extension CommandAbilityTests {
    func testTheOtherOneReplacesTheWaitingCard() async throws {
        let model = model()
        let sam = ActionCommand.reminder(title: "Call Sam", due: nil)
        let samLee = ActionCommand.reminder(title: "Call Sam Lee", due: nil)
        _ = await model.actionAnswer("remind me to call Sam")
        XCTAssertEqual(ActionPresence.shared.context?.command, sam)
        ActionPresence.shared.context = CommandContext(words: "remind me to call Sam", command: sam, candidates: [sam, samLee], at: Date())
        let other = await model.actionAnswer("no, the other one")
        XCTAssertEqual(other?.text, "Add the reminder “Call Sam Lee”? Say yes, or press Add.")
        XCTAssertEqual(ActionPresence.shared.pending?.command, samLee)
        XCTAssertEqual(ActionPresence.shared.context?.command, samLee)
        XCTAssertEqual(
            try file.load().map(\.outcomeCode),
            [.proposed, .awaitingConfirmation, .cancelled, .proposed, .awaitingConfirmation]
        )
        let back = await model.actionAnswer("the first one")
        XCTAssertEqual(back?.text, "Add the reminder “Call Sam”? Say yes, or press Add.")
    }

    func testFollowUpsThatCannotRunSaySo() async throws {
        let model = model()
        model.note("open my Budget spreadsheet", .openFile(path: "/synthetic/home/Budget.numbers"), target: "my Budget spreadsheet")
        let close = await model.actionAnswer("close it")
        XCTAssertEqual(close?.text, "I can't close one file yet: press ⌘W in it.")
        let other = await model.actionAnswer("the other one")
        XCTAssertEqual(other?.text, "That was the only one I found.")
        model.note("open Spotify", .openApp(name: "Spotify"))
        let reveal = await model.actionAnswer("show it in Finder")
        XCTAssertEqual(reveal?.text, "That isn't a file or folder.")
        XCTAssertTrue(try file.load().isEmpty)
    }

    func testTheSameForSomethingElseAsksTheOwnersWordsAgain() async {
        let model = model()
        model.note("remind me to call Sam", .reminder(title: "Call Sam", due: nil), target: "Sam")
        let same = await model.actionAnswer("do the same for Alex")
        XCTAssertEqual(same?.text, "Add the reminder “Call Alex”? Say yes, or press Add.")
        XCTAssertEqual(ActionPresence.shared.context?.words, "remind me to call Alex")
    }

    func testFollowUpsEndWithTheConversation() async throws {
        let model = model()
        let sam = ActionCommand.reminder(title: "Call Sam", due: nil)
        ActionPresence.shared.context = CommandContext(
            words: "remind me to call Sam", command: sam, at: Date().addingTimeInterval(-CommandContext.lifetime)
        )
        let stale = await model.actionAnswer("again")
        XCTAssertNil(stale)
        model.note("remind me to call Sam", sam)
        ActionPresence.shared.chattedSince = true
        let afterChat = await model.actionAnswer("again")
        XCTAssertNil(afterChat, "after a chat question, “again” is the chat's")
        ActionPresence.shared.chattedSince = false
        let again = await model.actionAnswer("do it again")
        XCTAssertEqual(again?.text, "Add the reminder “Call Sam”? Say yes, or press Add.")
        model.endVoiceConversation()
        XCTAssertNil(ActionPresence.shared.context)
        XCTAssertTrue(try file.load().allSatisfy { $0.domain == .reminder })
    }
}

/// Codex review #59: regressions for the five action-safety findings.
extension CommandAbilityTests {
    /// 1: a follow-up to something the model picked asks first again, instead of running at once.
    func testAgainAfterAModelPickAsksFirstAgain() async throws {
        let model = model(CommandStep(ability: .shortcut, value: "Work"))
        _ = await model.commandPlanAnswer("start my work day")
        XCTAssertEqual(ActionPresence.shared.context?.guessed, true)
        let again = await model.actionAnswer("again")
        XCTAssertEqual(again?.text, "Run the shortcut “Work”? Say yes, or press Run.")
        XCTAssertEqual(ActionPresence.shared.pending?.guessed, true)
        let entries = try file.load()
        XCTAssertEqual(entries.map(\.outcomeCode), [.proposed, .awaitingConfirmation, .cancelled, .proposed, .awaitingConfirmation])
        XCTAssertTrue(entries.allSatisfy { $0.decision.tier == .confirm })
    }

    /// 2: links and Finder aliases are followed, and the real target is what's checked and opened.
    func testFilesAreCheckedAtTheirRealTarget() throws {
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(
            at: home.appendingPathComponent("Cleanup.app/Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try manager.createDirectory(at: home.appendingPathComponent(".hidden", isDirectory: true), withIntermediateDirectories: true)
        let budget = home.appendingPathComponent("Budget 2026.numbers")
        try Data("synthetic".utf8).write(to: budget)
        let program = home.appendingPathComponent("tidy")
        try Data("#!/bin/sh\n".utf8).write(to: program)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let outside = folder.appendingPathComponent("Outside.numbers")
        try Data("synthetic".utf8).write(to: outside)
        let link = { (name: String, target: URL) throws -> String in
            let url = home.appendingPathComponent(name)
            try manager.createSymbolicLink(at: url, withDestinationURL: target)
            return url.path
        }
        let alias = { (name: String, target: URL) throws -> String in
            let url = home.appendingPathComponent(name)
            try URL.writeBookmarkData(target.bookmarkData(options: .suitableForBookmarkFile), to: url)
            return url.path
        }
        let real = budget.resolvingSymlinksInPath().path
        let any = FileName("Budget")
        XCTAssertEqual(try PanelModel.openable(link("Budget", budget), wanted: any, home: home.path), real)
        XCTAssertEqual(try PanelModel.openable(alias("Budget alias", budget), wanted: any, home: home.path), real)
        XCTAssertNil(try PanelModel.openable(link("Budget link", home.appendingPathComponent("Cleanup.app")), wanted: any, home: home.path))
        XCTAssertNil(try PanelModel.openable(alias("Budget app", home.appendingPathComponent("Cleanup.app")), wanted: any, home: home.path))
        XCTAssertNil(try PanelModel.openable(link("Budget tidy", program), wanted: any, home: home.path))
        XCTAssertNil(try PanelModel.openable(link("Budget out", outside), wanted: any, home: home.path))
        XCTAssertNil(try PanelModel.openable(link("Budget hidden", home.appendingPathComponent(".hidden")), wanted: any, home: home.path))
        XCTAssertNil(try PanelModel.openable(
            link("Budget gone", home.appendingPathComponent("missing.numbers")),
            wanted: any,
            home: home.path
        ))
        XCTAssertNil(PanelModel.openable(budget.path, wanted: FileName("Budget folder"), home: home.path), "not the kind asked for")
    }

    /// 4: an approved plan stops when the panel closes, and nothing is allowed while it's closed.
    func testAPlanStopsWhenThePanelCloses() async throws {
        let model = model()
        let request = ActionRequest(payload: ActionCommand.quitApp(name: "Synthetic Closed App").payload, origin: .ownerTyped)
        HUDPresence.shared.open = false
        let said = await model.runPlan([PlanStep(command: .quitApp(name: "Synthetic Closed App"), request: request, said: "quit it")])
        XCTAssertEqual(said, "I stopped the plan when the panel closed.")
        let entries = try file.load()
        XCTAssertEqual(entries.map(\.outcomeCode), [.cancelled])
        XCTAssertEqual(entries.first?.decision.tier, .never)
        XCTAssertTrue(entries.first?.decision.reasonCodes.contains(.panelClosed) == true)
        let decision = await model.log(request, .proposed)
        XCTAssertFalse(decision.allowed)
    }

    /// 5: a plan waiting on a message card resumes only after that card, and cancelling it cancels the rest.
    func testAPlansRestIsBoundToItsMessageCard() async throws {
        let model = model()
        let message = ActionRequest(payload: .message(recipientHandle: "synthetic-handle", text: "Synthetic"), origin: .ownerTyped)
        let step = ActionRequest(payload: ActionCommand.quitApp(name: "Synthetic Closed App").payload, origin: .ownerTyped)
        let rest = [PlanStep(command: .quitApp(name: "Synthetic Closed App"), request: step, said: "quit it")]
        ActionPresence.shared.planRest = (message.id, rest)
        let unrelated = await model.resumePlan(after: UUID())
        XCTAssertEqual(unrelated, "")
        XCTAssertNotNil(ActionPresence.shared.planRest)
        let draft = MessageDraft(channel: .message, name: "Synthetic", handle: "synthetic-handle", text: "Synthetic", subject: nil)
        ActionPresence.shared.pending = PendingAction(command: nil, message: draft, request: message, text: "Send?", at: Date(), needed: 2)
        await model.cancelAction()
        XCTAssertNil(ActionPresence.shared.planRest)
        XCTAssertEqual(try file.load().map(\.requestID), [message.id, step.id])
        XCTAssertEqual(try file.load().map(\.outcomeCode), [.cancelled, .cancelled])
        let later = await model.resumePlan(after: message.id)
        XCTAssertEqual(later, "", "nothing is left to resume")
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
