@testable import Aegis
import AegisKit
import XCTest

/// ADR-0038 stage 3: a stand-in for Claude Code asks Aegis to act over the pipes; the panel turns it into the owner's
/// own cards, and a second action is refused. Nothing here runs a real action: reminders and plans wait on cards.
@MainActor
final class ClaudeActionTests: XCTestCase {
    private var folder: URL!
    private var wasOpen = false

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-actions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        wasOpen = HUDPresence.shared.open
        HUDPresence.shared.open = true
        ActionPresence.shared.pending = nil
    }

    override func tearDown() async throws {
        HUDPresence.shared.open = wasOpen
        ActionPresence.shared.pending = nil
        try? FileManager.default.removeItem(at: folder)
    }

    /// Claude's reminder becomes the owner's card, waiting; its second action is refused, so nothing unplanned runs.
    func testAnActionBecomesACardAndASecondIsRefused() async throws {
        let first = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_reminder","arguments":{"title":"Call the office"}}}"#
        let second = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"open_app","arguments":{"name":"Calculator"}}}"#
        let runner = try ClaudeCodeRunner(executable: standIn(calls: [first, second], checks: ["press Add", "one action per request"]))
        let ending = await runner.run(
            system: "S", prompt: "Remind me to call the office, then open Calculator", choice: .standard, timeout: 30,
            reads: .init(
                source: ClaudeBrainTools(model: PanelModel(service: FixtureCore()), reads: ClaudeReads(service: FixtureCore())),
                enabled: [],
                acts: true
            )
        ) { _ in }
        XCTAssertEqual(ending, .outcome(.answer(text: "yes yes", model: "claude-opus-5-5")))
        let pending = try XCTUnwrap(ActionPresence.shared.pending)
        XCTAssertEqual(pending.command, .reminder(title: "Call the office", due: nil))
        XCTAssertEqual(pending.request.origin, .claude)
        XCTAssertEqual(pending.given, 0, "only the owner approves")
        let actions = await runner.lastActions
        XCTAssertEqual(actions, 1)
    }

    /// Several actions arrive as one plan card, judged step by step and waiting for the owner's Go.
    func testSeveralActionsArriveAsOnePlanCard() async throws {
        let steps = #"[{"tool":"add_reminder","arguments":{"title":"Bins"}},{"tool":"add_reminder","arguments":{"title":"Recycling"}}]"#
        let plan = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"propose_plan","arguments":{"steps":"# + steps + "}}}"
        let runner = try ClaudeCodeRunner(executable: standIn(calls: [plan], checks: ["the plan:"]))
        let ending = await runner.run(
            system: "S", prompt: "Bins and recycling reminders", choice: .standard, timeout: 30,
            reads: .init(
                source: ClaudeBrainTools(model: PanelModel(service: FixtureCore()), reads: ClaudeReads(service: FixtureCore())),
                enabled: [],
                acts: true
            )
        ) { _ in }
        XCTAssertEqual(ending, .outcome(.answer(text: "yes", model: "claude-opus-5-5")))
        let pending = try XCTUnwrap(ActionPresence.shared.pending)
        XCTAssertEqual(pending.plan.compactMap(\.command), [.reminder(title: "Bins", due: nil), .reminder(title: "Recycling", due: nil)])
        XCTAssertEqual(pending.plan.compactMap(\.request?.origin), [.claude, .claude])
        XCTAssertEqual(pending.button, "Go")
    }

    /// A card the owner hasn't answered, or a plan paused at a message, stays: Claude's card is refused.
    func testTheOwnersCardIsNeverReplaced() async {
        let model = PanelModel(service: FixtureCore())
        let owner = PendingAction(
            command: .reminder(title: "Owner's", due: nil),
            request: ActionRequest(payload: .reminder(title: "Owner's", due: nil), origin: .ownerTyped), text: "Owner's card", at: Date()
        )
        ActionPresence.shared.pending = owner
        for action in [
            ClaudeTools.Action.command(.reminder(title: "Claude's", due: nil)),
            .plan([.reminder(title: "A", due: nil), .reminder(title: "B", due: nil)]),
            .message(to: "Sam", text: "Hi", channel: .message),
        ] {
            let said = await model.claude(action)
            XCTAssertEqual(said, PanelModel.cardWaiting, "\(action)")
            XCTAssertEqual(ActionPresence.shared.pending?.request.id, owner.request.id)
        }
        ActionPresence.shared.pending = nil
        ActionPresence.shared.planRest = (after: UUID(), steps: [])
        defer { ActionPresence.shared.planRest = nil }
        _ = await model.claude(.command(.reminder(title: "Claude's", due: nil)))
        XCTAssertNil(ActionPresence.shared.pending, "a paused plan keeps the slot")
    }

    /// Once Claude's run has stopped, nothing it asked for appears or starts.
    func testNothingAppearsAfterTheRunStops() async {
        let model = PanelModel(service: FixtureCore())
        let late = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await model.claude(.command(.reminder(title: "Late", due: nil)))
        }
        _ = await late.value
        XCTAssertNil(ActionPresence.shared.pending)
    }

    /// An accepted action counts even when its run stops before it answers, so the request is never replayed.
    func testAnAcceptedActionStillCountsWhenTheRunStops() async throws {
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_reminder","arguments":{"title":"Bins"}}}"#
        let runner = try ClaudeCodeRunner(executable: standIn(calls: [call], checks: ["never"]))
        let ending = await runner.run(
            system: "S", prompt: "Remind me", choice: .standard, timeout: 3, reads: .init(source: SlowActions(), enabled: [], acts: true)
        ) { _ in }
        XCTAssertEqual(ending, .timedOut)
        let actions = await runner.lastActions
        XCTAssertEqual(actions, 1)
    }

    /// Without the run allowing actions, the tools aren't offered and a call is refused as unknown.
    func testReadOnlyRunsCantAct() async throws {
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_reminder","arguments":{"title":"Bins"}}}"#
        let runner = try ClaudeCodeRunner(executable: standIn(
            calls: [call],
            checks: ["Unknown tool"],
            tools: #"["mcp__aegis__recent_items"]"#
        ))
        let ending = await runner.run(
            system: "S", prompt: "Remind me", choice: .standard, timeout: 30,
            reads: .init(source: ClaudeReads(service: FixtureCore()), enabled: [.messages])
        ) { _ in }
        XCTAssertEqual(ending, .outcome(.answer(text: "yes", model: "claude-opus-5-5")))
        XCTAssertNil(ActionPresence.shared.pending)
    }

    /// A stand-in that answers the handshake, makes each tool call in turn, and replies with "yes" for each answer that
    /// contains its check.
    private func standIn(calls: [String], checks: [String], tools: String? = nil) throws -> String {
        let names = tools ?? "[" + ClaudeTools.Server(enabled: [], acts: true).toolNames.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        var turn = ""
        for (index, call) in calls.enumerated() {
            turn += """
              printf '%s\\n' '{"type":"control_request","request_id":"t\(index)","request":{"subtype":"mcp_message","server_name":"aegis","message":\(call)}}'
              IFS= read -r answer
              case "$answer" in *'\(checks[index])'*) words="$words yes" ;; *) words="$words no" ;; esac

            """
        }
        let script = """
        #!/bin/sh
        reply() { printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":%s}}\\n' "$1" "$2"; }
        words=""
        while IFS= read -r line; do
          case "$line" in
            *aegis-init*) reply aegis-init '{"account":{"subscription":"max","apiProvider":"firstParty"},"commands":[],"models":[]}' ;;
            *aegis-mcp*) reply aegis-mcp '{"mcpServers":[]}' ;;
            *aegis-settings*) reply aegis-settings '{"effective":{},"sources":[]}' ;;
            *'"type":"user"'*)
              printf '%s' '{"type":"system","subtype":"init","tools":\(names),"mcp_servers":[{"name":"aegis","status":"connected","source":"sdk"}],'
              echo '"plugins":[],"skills":[],"slash_commands":[],"apiKeySource":"none","model":"claude-opus-5-5"}'
        \(turn)      printf '{"type":"result","subtype":"success","is_error":false,"result":"%s","stop_reason":"end_turn"}\\n' "${words# }"
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

/// Takes far longer than any run to act, ignoring cancellation.
private struct SlowActions: ClaudeToolSource {
    func fetch(_: ClaudeTools.Call, enabled _: Set<ClaudeTools.Category>) async -> ClaudeTools.Payload {
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .refused("late")
    }
}
