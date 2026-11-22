@testable import Aegis
import AegisKit
import AppKit
import XCTest

/// ADR-0038 stage 5: with Claude chosen, the panel's questions go to a stand-in for Claude Code; when it can't answer,
/// the local model does and says so once; after an action it stops. Synthetic data only.
@MainActor
final class ClaudeBrainJobTests: XCTestCase {
    private var folder: URL!
    private var wasOpen = false

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-brain-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        wasOpen = HUDPresence.shared.open
        HUDPresence.shared.open = true
        ActionPresence.shared.pending = nil
        Brain.current = .claude
        PanelModel.resetFallback()
    }

    override func tearDown() async throws {
        Brain.current = .local
        HUDPresence.shared.open = wasOpen
        ActionPresence.shared.pending = nil
        PanelModel.brainRunner = ClaudeCodeRunner()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Claude reads with Aegis's tools and answers; the answer shows what it read and which model wrote it.
    func testClaudeAnswersAndShowsWhatItRead() async throws {
        PanelModel.brainRunner = try ClaudeCodeRunner(executable: standIn(turn: """
          call '{"name":"recent_items","arguments":{"limit":5}}'
          IFS= read -r answer
          delta 'You have news. '
          delta 'Alex asked about Saturday.'
          result 'You have news. Alex asked about Saturday.'
        """))
        let model = PanelModel(service: FixtureCore())
        await model.answerQuestion("What's new?", spoken: false)
        let answer = try XCTUnwrap(Self.answer(model))
        XCTAssertEqual(answer.text, "You have news. Alex asked about Saturday.")
        XCTAssertEqual(answer.model, "claude-opus-5-5")
        XCTAssertEqual(answer.eventIDs.count, 3, "the three items it read")
        XCTAssertEqual(model.partialAnswer, "")
    }

    /// Signed out before anything ran: the local model answers, saying so the first time only.
    func testTheLocalModelAnswersWhenClaudeCantAndSaysSoOnce() async throws {
        PanelModel.brainRunner = try ClaudeCodeRunner(executable: standIn(turn: "  :", signedIn: false))
        let model = PanelModel(service: FixtureCore())
        await model.answerQuestion("What's new?", spoken: false)
        XCTAssertEqual(
            Self.answer(model)?.text,
            "Claude Code isn't signed in, so I answered on this Mac. Alex Example asked you to call about Saturday."
        )
        await model.answerQuestion("Anything else?", spoken: false)
        XCTAssertEqual(Self.answer(model)?.text, "Alex Example asked you to call about Saturday.")
    }

    /// An action started, then Claude failed: Aegis stops and says so rather than asking the local model again.
    func testAfterAnActionItStopsInsteadOfReplaying() async throws {
        PanelModel.brainRunner = try ClaudeCodeRunner(executable: standIn(turn: """
          call '{"name":"add_reminder","arguments":{"title":"Call the office"}}'
          IFS= read -r answer
          exit 3
        """))
        let model = PanelModel(service: FixtureCore())
        // Not a fixed command ("remind me to…" is answered on this Mac before Claude is asked).
        await model.answerQuestion("Sort out the office thing for me", spoken: false)
        XCTAssertEqual(Self.answer(model)?.text, "Claude stopped partway, after starting an action. Check what it did before asking again.")
        XCTAssertEqual(ActionPresence.shared.pending?.request.origin, .claude, "the card it made still waits for the owner")
    }

    /// With this Mac chosen, Claude never runs.
    func testThisMacNeverRunsClaude() async throws {
        Brain.current = .local
        PanelModel.brainRunner = try ClaudeCodeRunner(executable: standIn(turn: "  result 'From Claude'"))
        let model = PanelModel(service: FixtureCore())
        await model.answerQuestion("What's new?", spoken: false)
        XCTAssertEqual(Self.answer(model)?.text, "Alex Example asked you to call about Saturday.")
    }

    /// Reply drafts come from Claude for a named person; one known only by a phone number or address stays on this Mac.
    func testDraftsGoToClaudeOnlyWithAName() async throws {
        PanelModel.brainRunner = try ClaudeCodeRunner(executable: standIn(turn: "  result 'Sure, Saturday works.'"))
        let model = PanelModel(service: FixtureCore())
        await model.refresh()
        await model.draftReply(Brief.Person(id: "contact:1", name: "Alex Example"))
        guard case let .ready(draft)? = model.drafts["contact:1"]
        else { return XCTFail("\(String(describing: model.drafts["contact:1"]))") }
        XCTAssertEqual(draft.text, "Sure, Saturday works.")
        XCTAssertEqual(draft.model, "claude-opus-5-5")
        await model.draftReply(Brief.Person(id: "handle:1", name: "+61 400 000 001"))
        if case let .ready(local)? = model.drafts["handle:1"] {
            XCTAssertNotEqual(local.model, "claude-opus-5-5")
        }
    }

    /// The time, sums and memory commands stay on this Mac with Claude chosen: Claude isn't asked.
    func testInstantAnswersAndMemoryStayOnThisMac() async throws {
        PanelModel.brainRunner = try ClaudeCodeRunner(executable: standIn(turn: "  result 'From Claude'"))
        let model = PanelModel(service: FixtureCore())
        for question in ["What's 12 times 4?", "What time is it?", "Remember that my locker is 42"] {
            await model.answerQuestion(question, spoken: false)
            XCTAssertNotEqual(Self.answer(model)?.text, "From Claude", question)
        }
    }

    /// Stop while Claude is writing ends the run at once, and nothing arrives afterwards.
    func testStopEndsTheRunningJob() async throws {
        PanelModel.brainRunner = try ClaudeCodeRunner(executable: standIn(turn: """
          sleep 20
          result 'Too late'
        """))
        let model = PanelModel(service: FixtureCore())
        let began = Date()
        let asking = Task { await model.answerQuestion("Sort out the office thing for me", spoken: false) }
        try await Task.sleep(for: .seconds(1.5))
        model.clearAnswer()
        await asking.value
        XCTAssertLessThan(Date().timeIntervalSince(began), 8, "the job ended with Stop, not after its 20 seconds")
        XCTAssertNotEqual(Self.answer(model)?.text, "Too late")
    }

    /// A job that's lost its authority (a new question, Stop, closing the panel, a changed switch) can't read or act.
    func testAJobWithoutAuthorityCantReadOrAct() async {
        let tools = ClaudeBrainTools(model: PanelModel(service: FixtureCore()), reads: ClaudeReads(service: FixtureCore()), live: { false })
        let read = await tools.fetch(.recentItems(limit: 5), enabled: Set(ClaudeTools.Category.allCases))
        XCTAssertEqual(read, .refused("Stopped."))
        let act = await tools.fetch(.act(.command(.reminder(title: "Late", due: nil))), enabled: [])
        XCTAssertEqual(act, .refused("Stopped."))
        XCTAssertNil(ActionPresence.shared.pending)
    }

    /// Switching the brain, or turning a source off, ends the running job's authority.
    func testSettingsChangesRevokeTheRunningJob() {
        let settings = BrainSettings(installed: false)
        let before = PanelModel.brainGeneration
        settings.reads.insert(.mail)
        XCTAssertEqual(PanelModel.brainGeneration, before, "turning a source on keeps the job")
        settings.reads.remove(.mail)
        XCTAssertGreaterThan(PanelModel.brainGeneration, before)
        let after = PanelModel.brainGeneration
        settings.brain = .local
        XCTAssertGreaterThan(PanelModel.brainGeneration, after)
        settings.reads = Set(ClaudeTools.Category.allCases)
    }

    func testSpeechFollowsFinishedSentences() {
        XCTAssertEqual(PanelModel.sentences("  Hello there. How are"), "Hello there.")
        XCTAssertEqual(PanelModel.sentences("It's 5.5 km away! Then"), "It's 5.5 km away!")
        XCTAssertEqual(PanelModel.sentences("No end yet"), "")
        XCTAssertEqual(PanelModel.sentences("Done."), "Done.")
    }

    /// Claude's reply types out at CHAT's pace even when it arrives in one large piece (#210).
    func testTheReplyTypesOutRatherThanAppearingAtOnce() async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "reduce motion shows it at once")
        let reply = String(repeating: "Saturday works for the picnic. ", count: 6).trimmingCharacters(in: .whitespaces)
        PanelModel.brainRunner = try ClaudeCodeRunner(executable: standIn(turn: """
          delta '\(reply)'
          sleep 1
          result '\(reply)'
        """))
        let model = PanelModel(service: FixtureCore())
        let asking = Task { await model.answerQuestion("What do you make of the picnic plan?", spoken: false) }
        var lengths: Set<Int> = []
        let deadline = Date().addingTimeInterval(60)
        while Self.answer(model) == nil, Date() < deadline {
            lengths.insert(model.partialAnswer.count)
            try await Task.sleep(for: .milliseconds(5))
        }
        await asking.value
        XCTAssertEqual(Self.answer(model)?.text, reply)
        XCTAssertGreaterThanOrEqual(lengths.filter { $0 > 0 && $0 < reply.count }.count, 3, "shown in steps, not whole")
    }

    /// A question that replaces a running one never shows that one's partial reply (#210).
    func testANewQuestionNeverShowsTheLastOnesPartialReply() {
        let model = PanelModel(service: FixtureCore())
        model.partialAnswer = "From the last question"
        _ = model.beginQuestion("What else?")
        XCTAssertEqual(model.partialAnswer, "")
    }

    /// A fast reply's passages are synthesised one at a time and in order: the bundled voice refuses a second one
    /// meanwhile. After a failure the rest are left for the system voice without asking again (#210).
    func testSpokenPassagesAreSynthesisedOneAtATime() async {
        let (parts, queue) = AsyncStream<String>.makeStream()
        for part in ["One.", "Two.", "Three.", "Four."] {
            queue.yield(part)
        }
        queue.finish()
        let (ready, sink) = AsyncStream<(String, Data?)>.makeStream()
        let synthesis = Synthesis()
        await Voice.synthesize(parts, into: sink) { await synthesis.make($0) }
        var results: [(String, Bool)] = []
        for await (part, data) in ready {
            results.append((part, data != nil))
        }
        XCTAssertEqual(results.map(\.0), ["One.", "Two.", "Three.", "Four."])
        XCTAssertEqual(results.map(\.1), [true, true, false, false])
        let asked = await synthesis.asked
        let most = await synthesis.most
        XCTAssertEqual(asked, ["One.", "Two.", "Three."], "nothing asked after the failure")
        XCTAssertEqual(most, 1, "never two at once")
    }

    private static func answer(_ model: PanelModel) -> Answer? {
        if case let .answered(_, answer) = model.askState {
            return answer
        }
        return nil
    }

    /// A stand-in that answers the handshake (signed in or not), then runs `turn` when the prompt arrives, with helpers
    /// to call a tool, type a piece of the reply and finish it.
    private func standIn(turn: String, signedIn: Bool = true) throws -> String {
        let account = signedIn ? #"{"subscription":"max","apiProvider":"firstParty"}"# : #"{"tokenSource":"none","apiProvider":"firstParty"}"#
        // The read tools: a subset every run allows (a run that can't act refuses action tools).
        let tools = "[" + ClaudeTools.Server(enabled: Set(ClaudeTools.Category.allCases)).toolNames.map { "\"\($0)\"" }
            .joined(separator: ",") + "]"
        let script = """
        #!/bin/sh
        reply() { printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":%s}}\\n' "$1" "$2"; }
        rpc='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":%s}'
        call() { printf '{"type":"control_request","request_id":"t1","request":{"subtype":"mcp_message","server_name":"aegis","message":'"$rpc"'}}\\n' "$1"; }
        delta() { printf '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}}\\n' "$1"; }
        result() { printf '{"type":"result","subtype":"success","is_error":false,"result":"%s","stop_reason":"end_turn"}\\n' "$1"; }
        while IFS= read -r line; do
          case "$line" in
            *aegis-init*) reply aegis-init '{"account":\(account),"commands":[],"models":[]}' ;;
            *aegis-mcp*) reply aegis-mcp '{"mcpServers":[]}' ;;
            *aegis-settings*) reply aegis-settings '{"effective":{},"sources":[]}' ;;
            *'"type":"user"'*)
              printf '%s' '{"type":"system","subtype":"init","tools":\(tools),"mcp_servers":[{"name":"aegis","status":"connected","source":"sdk"}],'
              echo '"plugins":[],"skills":[],"slash_commands":[],"apiKeySource":"none","model":"claude-opus-5-5"}'
        \(turn)
              ;;
          esac
        done

        """
        let file = folder.appendingPathComponent("claude-" + UUID().uuidString.prefix(8))
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file.path
    }
}

/// A stand-in for the bundled voice that counts overlapping requests and fails on "Three.".
private actor Synthesis {
    private(set) var asked: [String] = []
    private(set) var most = 0
    private var running = 0

    func make(_ text: String) async -> Data? {
        asked.append(text)
        running += 1
        most = max(most, running)
        try? await Task.sleep(for: .milliseconds(20))
        running -= 1
        return text == "Three." ? nil : Data(text.utf8)
    }
}
