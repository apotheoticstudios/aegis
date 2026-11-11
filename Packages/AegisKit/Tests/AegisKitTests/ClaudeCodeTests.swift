@testable import AegisKit
import Foundation
import XCTest

/// ADR-0038 stage 1: the locked-down command line and environment, and reading Claude Code's stream (synthetic
/// events shaped like Claude Code 2.1's).
final class ClaudeCodeTests: XCTestCase {
    func testCommandLineTurnsEverythingOffAndTakesThePromptOnInput() {
        let choice = ClaudeCode.Choice(model: "sonnet", effort: .high)
        let arguments = ClaudeCode.arguments(executable: "/bin/claude", choice: choice, system: "S")
        XCTAssertEqual(arguments.first, "/bin/claude")
        for (flag, value) in [
            ("--tools", ""),
            ("--setting-sources", ""),
            ("--model", "sonnet"),
            ("--effort", "high"),
            ("--system-prompt", "S"),
            ("--input-format", "stream-json"),
            ("--output-format", "stream-json"),
        ] {
            let index = arguments.firstIndex(of: flag)
            XCTAssertEqual(index.map { arguments[$0 + 1] }, value, flag)
        }
        for flag in [
            "--strict-mcp-config",
            "--safe-mode",
            "--restricted",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--no-chrome",
            "--include-partial-messages",
            "--verbose",
        ] {
            XCTAssertTrue(arguments.contains(flag), flag)
        }
        XCTAssertFalse(arguments.contains("--bare"), "bare mode skips the subscription sign-in")
        XCTAssertFalse(arguments.contains("--mcp-config"))
    }

    /// Only these variables reach Claude Code: `env -i` drops everything launchd would add.
    func testEnvironmentIsRebuiltFromNothing() {
        let environment = ClaudeCode.environment(home: "/h", user: "u", temporary: "/t", language: "en_AU.UTF-8")
        XCTAssertEqual(environment["HOME"], "/h")
        XCTAssertEqual(environment["USER"], "u")
        XCTAssertEqual(environment["TMPDIR"], "/t")
        XCTAssertEqual(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1")
        XCTAssertEqual(Set(environment.keys), [
            "HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
            "DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "DISABLE_BUG_COMMAND", "DISABLE_AUTOUPDATER",
        ])
        let command = ClaudeCode.command(executable: "/bin/claude", choice: .standard, system: "S", environment: ["B": "2", "A": "1"])
        XCTAssertEqual(Array(command.prefix(5)), ["/usr/bin/env", "-i", "A=1", "B=2", "/bin/claude"])
        XCTAssertEqual(Array(command.dropFirst(4)), ClaudeCode.arguments(executable: "/bin/claude", choice: .standard, system: "S"))
    }

    func testOnlyPlainModelNamesAreAccepted() {
        for name in ["default", "opus", "claude-fable-5-1[1m]", "claude-haiku-5-5"] {
            XCTAssertTrue(ClaudeCode.Choice(model: name, effort: .low).isValid, name)
        }
        for name in ["", "--tools", "-p", "opus sonnet", "Opus", String(repeating: "a", count: 65)] {
            XCTAssertFalse(ClaudeCode.Choice(model: name, effort: .low).isValid, name)
        }
    }

    func testPromptIsOneUserLine() throws {
        let line = ClaudeCode.prompt("What's \"quoted\"?\nNext line")
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "user")
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "What's \"quoted\"?\nNext line")
    }

    /// The handshake passes, then the reply types as it streams, whatever the chunking, and ends as the answer.
    func testAnswerStreamsAfterTheHandshake() {
        let stream = Self.handshake() + [Self.initEvent(), Self.delta("Hel"), Self.delta("lo."), Self.result("Hello.")]
        let bytes = Data(stream.joined())
        var session = ClaudeCode.Session()
        var events: [ClaudeCode.Session.Event] = []
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = min(start + 7, bytes.endIndex)
            events += session.feed(bytes[start ..< end])
            start = end
        }
        XCTAssertEqual(events, [
            .ready([ClaudeCode.Model(value: "opus", name: "Opus"), ClaudeCode.Model(value: "haiku", name: "Haiku")]),
            .text("Hel"), .text("lo."), .finished(.answer(text: "Hello.", model: "claude-opus-5-5")),
        ])
        XCTAssertTrue(session.finished)
        XCTAssertEqual(session.feed(Self.delta("more")), [])
    }

    func testSignedOutEndsAtTheHandshake() {
        var session = ClaudeCode.Session()
        let events = session.feed(Data(Self.handshake(plan: nil).joined()))
        XCTAssertEqual(events, [.finished(.signedOut)])
    }

    /// Anything Aegis didn't ask for stops the run before the prompt, or as the turn starts.
    func testUnexpectedConfigurationIsRefused() {
        let cases: [([Data], [String])] = [
            (Self.handshake(apiKey: "ANTHROPIC_API_KEY"), ["api_key"]),
            (Self.handshake(provider: "bedrock"), ["provider"]),
            (Self.handshake(servers: [["name": "files", "status": "connected"]]), ["mcp_servers"]),
            (Self.handshake(sources: ["policySettings"]), ["settings"]),
            (Self.handshake(effective: ["hooks": [:]]), ["settings"]),
            (Self.handshake(commands: [["name": "deploy"]]), ["commands"]),
            (Self.handshake() + [Self.initEvent(tools: ["Bash"])], ["tools"]),
            (Self.handshake() + [Self.initEvent(plugins: [["name": "x", "source": "x@market"]])], ["plugins"]),
            ([Self.initEvent()], ["order"]),
        ]
        // A missing or renamed field is refused, never read as empty.
        for key in ["settings.effective", "settings.sources", "init.account", "init.commands", "init.models", "mcp.mcpServers"] {
            var session = ClaudeCode.Session()
            XCTAssertEqual(session.feed(Data(Self.handshake(drop: key).joined())).last, .finished(.refused(["schema"])), key)
        }
        for key in ["tools", "mcp_servers", "plugins", "skills", "slash_commands", "apiKeySource"] {
            var session = ClaudeCode.Session()
            XCTAssertEqual(
                session.feed(Data((Self.handshake() + [Self.initEvent(drop: key)]).joined())).last,
                .finished(.refused(["schema"])),
                key
            )
        }
        for (lines, codes) in cases {
            var session = ClaudeCode.Session()
            XCTAssertEqual(session.feed(Data(lines.joined())).last, .finished(.refused(codes)), "\(codes)")
        }
        var allowed = ClaudeCode.Session(servers: ["aegis"])
        XCTAssertEqual(allowed.feed(Data(Self.handshake(servers: [["name": "aegis"]]).joined())).count, 1)
    }

    func testPlanLimitCarriesItsResetTime() {
        let limit = Self.line(["type": "rate_limit_event", "rate_limit_info": ["status": "rejected", "resetsAt": 1_800_000_000]])
        let assistant = Self.line(["type": "assistant", "error": "rate_limit", "message": ["content": []]])
        var session = ClaudeCode.Session()
        let events = session.feed(Data((Self.handshake() + [Self.initEvent(), limit, assistant, Self.result("x", error: true)]).joined()))
        XCTAssertEqual(events.last, .finished(.limit(resets: Date(timeIntervalSince1970: 1_800_000_000))))
    }

    func testFailuresAreCodes() {
        var signedOut = ClaudeCode.Session()
        let assistant = Self.line(["type": "assistant", "error": "authentication_failed"])
        XCTAssertEqual(
            signedOut.feed(Data((Self.handshake() + [Self.initEvent(), assistant, Self.result("Not logged in", error: true)]).joined()))
                .last,
            .finished(.signedOut)
        )
        var declined = ClaudeCode.Session()
        let refusal = Self.line(["type": "result", "is_error": false, "result": "No.", "stop_reason": "refusal"])
        XCTAssertEqual(declined.feed(Data((Self.handshake() + [Self.initEvent(), refusal]).joined())).last, .finished(.declined))
        var early = ClaudeCode.Session()
        XCTAssertEqual(early.feed(Self.delta("x") + Self.result("x")), [.finished(.failed("no_init"))], "no text before the checks")
        var long = ClaudeCode.Session()
        XCTAssertEqual(long.feed(Data(repeating: 0x41, count: ClaudeCode.Session.maxLine + 1)), [.finished(.failed("line_too_long"))])
    }

    func testReplyIsCapped() {
        var session = ClaudeCode.Session()
        let big = String(repeating: "a", count: ClaudeCode.Session.maxReply)
        let events = session.feed(Data((Self.handshake() + [Self.initEvent(), Self.delta(big), Self.delta("b")]).joined()))
        XCTAssertEqual(events.count, 2, "ready, then one capped piece")
    }

    // MARK: Synthetic events

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Shaped like Claude Code 2.1.306's answers: a subscription sign-in names its plan; signed out, it reports
    /// `tokenSource: none`. `drop` removes one field, as "body.field".
    private static func handshake(
        plan: String? = "max", apiKey: String? = nil, provider: String = "firstParty", servers: [[String: String]] = [],
        sources: [String] = [], effective: [String: Any] = [:], commands: [[String: String]] = [], drop: String? = nil
    ) -> [Data] {
        var account: [String: Any] = ["apiProvider": provider]
        account["subscription"] = plan
        account["tokenSource"] = plan == nil ? "none" : nil
        account["apiKeySource"] = apiKey
        let models: [[String: String]] = [
            ["value": "opus", "displayName": "Opus"],
            ["value": "--bad", "displayName": "Bad"],
            ["value": "haiku", "displayName": "Haiku"],
        ]
        func response(_ id: String, _ name: String, _ body: [String: Any]) -> Data {
            let body = body.filter { name + "." + $0.key != drop }
            return line(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": body]])
        }
        return [
            response("aegis-settings", "settings", ["effective": effective, "sources": sources]),
            response("aegis-init", "init", ["account": account, "models": models, "commands": commands]),
            response("aegis-mcp", "mcp", ["mcpServers": servers]),
        ]
    }

    private static func initEvent(
        tools: [String] = [], plugins: [[String: String]] = [["name": "a", "source": "a@builtin"]], drop: String? = nil
    ) -> Data {
        line([
            "type": "system", "subtype": "init", "tools": tools, "mcp_servers": [], "plugins": plugins, "skills": [],
            "slash_commands": [], "apiKeySource": "none", "model": "claude-opus-5-5",
        ].filter { $0.key != drop })
    }

    private static func delta(_ text: String) -> Data {
        line(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": text]]])
    }

    private static func result(_ text: String, error: Bool = false) -> Data {
        line(["type": "result", "subtype": "success", "is_error": error, "result": text, "stop_reason": "end_turn"])
    }
}
