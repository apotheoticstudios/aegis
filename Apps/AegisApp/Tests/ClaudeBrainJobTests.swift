@testable import Aegis
import AegisKit
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

    func testSpeechFollowsFinishedSentences() {
        XCTAssertEqual(PanelModel.sentences("  Hello there. How are"), "Hello there.")
        XCTAssertEqual(PanelModel.sentences("It's 5.5 km away! Then"), "It's 5.5 km away!")
        XCTAssertEqual(PanelModel.sentences("No end yet"), "")
        XCTAssertEqual(PanelModel.sentences("Done."), "Done.")
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
