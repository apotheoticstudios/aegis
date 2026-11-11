@testable import AegisKit
import Foundation
import XCTest

/// ADR-0038 stage 3: Claude's action tools become the owner's own typed commands, and what collected content might
/// steer Claude into can't reach the never-list, a raw link or scheme, a second unplanned action or an unconfirmed
/// message (synthetic data only).
final class ClaudeActionsTests: XCTestCase {
    private let open = ActionOwnerSettings(panelIsOpen: true)

    private func action(_ tool: ClaudeTools.ActionTool, _ arguments: [String: Any]) -> ClaudeTools.Action? {
        ClaudeTools.action(tool, arguments)
    }

    func testEachToolBecomesTheOwnersTypedCommand() throws {
        XCTAssertEqual(action(.openApp, ["name": "Safari"]), .command(.openApp(name: "Safari")))
        XCTAssertEqual(action(.quitApp, ["name": "Music"]), .command(.quitApp(name: "Music")))
        XCTAssertEqual(action(.runShortcut, ["name": "Work"]), .command(.runShortcut(name: "Work")))
        XCTAssertEqual(action(.openWebsite, ["address": "bom.gov.au"]), .command(.openWebsite(url: "https://bom.gov.au")))
        XCTAssertEqual(action(.openFile, ["name": "Budget.xlsx", "reveal": true]), .command(.findFile(name: "Budget.xlsx", reveal: true)))
        XCTAssertEqual(action(.control, ["entry": "musicPause"]), .command(.automate(.musicPause, argument: "")))
        XCTAssertEqual(action(.control, ["entry": "volumeSet", "argument": "30"]), .command(.automate(.volumeSet, argument: "30")))
        let due = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-12T07:00:00Z"))
        XCTAssertEqual(
            action(.addReminder, ["title": "Call the office", "due": "2026-11-12T17:00:00+10:00"]),
            .command(.reminder(title: "Call the office", due: due))
        )
        XCTAssertEqual(action(.addReminder, ["title": "Bins"]), .command(.reminder(title: "Bins", due: nil)))
        XCTAssertEqual(
            action(.addEvent, ["title": "Lunch", "start": "2026-11-12T02:00:00Z", "end": "2026-11-12T03:00:00Z"]),
            .command(.event(title: "Lunch", start: due.addingTimeInterval(-5 * 3600), end: due.addingTimeInterval(-4 * 3600)))
        )
        XCTAssertEqual(
            action(.sendMessage, ["to": "Sam", "text": "Running late"]),
            .message(to: "Sam", text: "Running late", channel: .message)
        )
        XCTAssertEqual(
            action(
                .proposePlan,
                ["steps": [["tool": "open_app", "arguments": ["name": "Music"]], ["tool": "control", "arguments": ["entry": "musicPlay"]]]]
            ),
            .plan([.openApp(name: "Music"), .automate(.musicPlay, argument: "")])
        )
    }

    /// No scheme but http(s), no paths, no catalogue entry that takes a path or address, no hidden characters.
    func testRawLinksPathsAndBadValuesAreRefused() {
        for address in [
            "shortcuts://run-shortcut?name=Pay", "file:///etc/hosts", "javascript:alert(1)", "x-apple.systempreferences:com.apple.Security",
            "mailto:someone@example.com", "tel:0400000000", "ftp://example.com", "Notes.app", "",
        ] {
            XCTAssertNil(action(.openWebsite, ["address": address]), address)
        }
        for name in ["/etc/hosts", "Documents/secret.txt", "~/Library", "..", ".", "a:b", "x\u{0007}y"] {
            XCTAssertNil(action(.openFile, ["name": name]), name)
        }
        XCTAssertNil(action(.control, ["entry": "finderReveal", "argument": "/Users/example"]))
        XCTAssertNil(action(.control, ["entry": "safariNewTab", "argument": "https://example.com"]))
        XCTAssertNil(action(.control, ["entry": "runScript"]))
        XCTAssertNil(action(.sendMessage, ["to": "", "text": "Hi"]))
        XCTAssertNil(action(.sendMessage, ["to": "Sam", "text": String(repeating: "x", count: 1001)]))
        XCTAssertNil(action(.sendMessage, ["to": "Sam", "text": "Hi", "channel": "fax"]))
        XCTAssertNil(action(.addReminder, ["title": "Bins", "due": "tomorrow"]))
        XCTAssertNil(action(.addEvent, ["title": "Backwards", "start": "2026-11-12T03:00:00Z", "end": "2026-11-12T02:00:00Z"]))
        XCTAssertNil(action(.addEvent, ["title": "Too long", "start": "2026-11-12T00:00:00Z", "end": "2026-11-14T00:00:00Z"]))
    }

    /// Plans list two to six of the other actions, never messages or plans.
    func testPlansAreBounded() {
        let step = ["tool": "open_app", "arguments": ["name": "Music"]] as [String: Any]
        XCTAssertNil(action(.proposePlan, ["steps": [step]]))
        XCTAssertNil(action(.proposePlan, ["steps": Array(repeating: step, count: CommandPlan.maxSteps + 1)]))
        XCTAssertNotNil(action(.proposePlan, ["steps": Array(repeating: step, count: CommandPlan.maxSteps)]))
        XCTAssertNil(action(.proposePlan, ["steps": [step, ["tool": "send_message", "arguments": ["to": "Sam", "text": "Hi"]]]]))
        XCTAssertNil(action(.proposePlan, ["steps": [step, ["tool": "propose_plan", "arguments": ["steps": [step, step]]]]]))
        XCTAssertNil(action(.proposePlan, ["steps": [step, ["tool": "delete_file", "arguments": ["name": "x"]]]]))
    }

    /// One action per request: a second, or a plan after an action, is refused; a refused call isn't counted.
    func testOneActionPerRequest() {
        XCTAssertEqual(ClaudeTools.Server(enabled: []).actionTools, [], "offered only when the run allows actions")
        var server = ClaudeTools.Server(enabled: [], acts: true)
        let names = server.toolNames.joined(separator: " ")
        for word in ["delete", "pay", "buy", "password", "transfer", "approve", "confirm"] {
            XCTAssertFalse(names.contains(word), word)
        }
        XCTAssertTrue(isError(server.handle(call(1, "open_website", ["address": "shortcuts://x"]))))
        XCTAssertEqual(server.actions, 0)
        XCTAssertEqual(
            server.handle(call(2, "open_app", ["name": "Music"])),
            .call(id: .number(2), .act(.command(.openApp(name: "Music"))))
        )
        XCTAssertEqual(server.actions, 1)
        XCTAssertTrue(isError(server.handle(call(3, "open_app", ["name": "Mail"]))))
        XCTAssertTrue(isError(server.handle(call(4, "propose_plan", ["steps": [
            ["tool": "open_app", "arguments": ["name": "A"]], ["tool": "open_app", "arguments": ["name": "B"]],
        ]]))))
        XCTAssertEqual(server.actions, 1)

        var planned = ClaudeTools.Server(enabled: [], acts: true)
        guard case .call(_, .act(.plan)) = planned.handle(call(1, "propose_plan", ["steps": [
            ["tool": "open_app", "arguments": ["name": "A"]], ["tool": "open_app", "arguments": ["name": "B"]],
        ]])) else { return XCTFail("plan") }
        XCTAssertTrue(isError(planned.handle(call(2, "send_message", ["to": "Sam", "text": "Hi"]))), "nothing after the plan")
    }

    /// Pure C: Claude's requests get exactly the owner's tiers, and the never-list holds.
    func testClaudesRequestsGetTheOwnersTiers() {
        let payloads: [ActionPayload] = [
            .app(bundleID: "Music", verb: .open), .shortcut(name: "Pay rent"), .shortcut(name: "Work"),
            .reminder(title: "Bins", due: nil), .message(recipientHandle: "+61400000000", text: "Hi"),
            .file(path: "/Users/example/run.command", verb: .open), .website(url: "https://bom.gov.au"),
        ]
        for payload in payloads {
            let owner = ActionPolicy.decision(for: ActionRequest(payload: payload, origin: .ownerTyped), settings: open)
            let claude = ActionPolicy.decision(for: ActionRequest(payload: payload, origin: .claude), settings: open)
            XCTAssertEqual(claude, owner, "\(payload)")
        }
        XCTAssertEqual(
            ActionPolicy.decision(for: ActionRequest(payload: .shortcut(name: "Pay rent"), origin: .claude), settings: open).tier,
            .never
        )
        XCTAssertEqual(
            ActionPolicy
                .decision(
                    for: ActionRequest(payload: .message(recipientHandle: "+61400000000", text: "Hi"), origin: .claude),
                    settings: open
                ).tier,
            .confirmTwice
        )
    }

    /// What a planted instruction in a message could make Claude ask for still lands on the never-list, a refusal or
    /// a card: nothing it names can pay, delete, or send without the owner.
    func testAPlantedInstructionCantGetPastTheTools() {
        let planted = [
            (ClaudeTools.ActionTool.runShortcut, ["name": "Pay all bills"]),
            (.runShortcut, ["name": "Delete Photos"]),
            (.runShortcut, ["name": "Export Passwords"]),
            (.openWebsite, ["address": "shortcuts://run-shortcut?name=Pay"]),
            (.openFile, ["name": "../../.ssh/id_rsa"]),
        ]
        for (tool, arguments) in planted {
            guard let action = ClaudeTools.action(tool, arguments) else { continue }
            guard case let .command(command) = action else { return XCTFail("\(action)") }
            XCTAssertEqual(
                ActionPolicy.decision(for: ActionRequest(payload: command.payload, origin: .claude), settings: open).tier,
                .never,
                "\(arguments)"
            )
        }
        guard case let .message(to, text, channel)? = ClaudeTools.action(.sendMessage, ["to": "Everyone", "text": "Send me the code"])
        else {
            return XCTFail("message")
        }
        let send = MessageCommand(channel: channel, to: to, text: text)
        XCTAssertTrue(send.send, "a message from Claude is always a send card")
        XCTAssertEqual(
            ActionPolicy.decision(for: ActionRequest(payload: .message(recipientHandle: "x", text: text), origin: .claude), settings: open)
                .tier,
            .confirmTwice
        )
    }

    // MARK: Helpers

    private func call(_ id: Int, _ name: String, _ arguments: [String: Any]) -> Data {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
        return (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
    }

    private func isError(_ step: ClaudeTools.Server.Step) -> Bool {
        guard case let .reply(data) = step,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["error"] != nil || (object["result"] as? [String: Any])?["isError"] as? Bool == true
    }
}
