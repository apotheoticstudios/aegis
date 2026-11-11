import Foundation

/// Claude Code run headless with the owner's Claude plan (ADR-0038): its fixed command line and rebuilt
/// environment, the handshake that checks its effective configuration before any prompt is sent, and the in-memory
/// reading of its event stream. The app runs the job; this decides what it means.
public enum ClaudeCode {
    /// A model the owner's plan offers, as Claude Code lists it.
    public struct Model: Codable, Equatable, Sendable, Identifiable {
        public let value: String
        public let name: String
        public var id: String {
            value
        }

        public init(value: String, name: String) {
            self.value = value
            self.name = name
        }
    }

    /// How hard Claude thinks before answering.
    public enum Effort: String, Codable, CaseIterable, Sendable {
        case low, medium, high

        public var label: String {
            switch self {
            case .low: "Quick"
            case .medium: "Balanced"
            case .high: "Thorough"
            }
        }
    }

    /// The owner's model and effort, kept on the Mac.
    public struct Choice: Codable, Equatable, Sendable {
        public var model: String
        public var effort: Effort

        /// Claude Code's recommended model.
        public static let standard = Choice(model: "default", effort: .medium)

        public init(model: String, effort: Effort) {
            self.model = model
            self.effort = effort
        }

        /// A model name Claude Code takes as one argument value, never as a flag.
        public var isValid: Bool {
            model.range(of: #"^[a-z0-9][a-z0-9.\-\[\]]{0,63}$"#, options: .regularExpression) != nil
        }
    }

    /// The whole command line: no built-in tools, no settings files, customisations, commands or Chrome, nothing
    /// saved; the prompt arrives on standard input. `tools` (full names) are Aegis's own, served by Aegis over the
    /// control channel and allowed without asking; with none, there are no MCP servers at all.
    public static func arguments(executable: String, choice: Choice, system: String, tools: [String] = []) -> [String] {
        let served = tools.isEmpty ? [] : [
            "--mcp-config", #"{"mcpServers":{"\#(ClaudeTools.server)":{"type":"sdk","name":"\#(ClaudeTools.server)"}}}"#,
            "--allowedTools", tools.joined(separator: ","),
        ]
        return [
            executable, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--model", choice.model, "--effort", choice.effort.rawValue,
            "--system-prompt", system, "--no-session-persistence", "--tools", "", "--strict-mcp-config",
        ] + served + ["--setting-sources", "", "--safe-mode", "--restricted", "--disable-slash-commands", "--no-chrome"]
    }

    /// The job's whole environment. The real home folder and account name are how Claude Code finds the owner's
    /// sign-in in the Keychain; nonessential traffic is off. No API key, endpoint, proxy or provider switch.
    public static func environment(home: String, user: String, temporary: String, language: String) -> [String: String] {
        [
            "HOME": home, "USER": user, "LOGNAME": user, "TMPDIR": temporary, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": language, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_TELEMETRY": "1",
            "DISABLE_ERROR_REPORTING": "1", "DISABLE_BUG_COMMAND": "1", "DISABLE_AUTOUPDATER": "1",
        ]
    }

    /// What launchd runs: `env -i` first, because launchd adds a job's variables to its own environment rather than
    /// replacing it, so only `environment` reaches Claude Code.
    public static func command(
        executable: String, choice: Choice, system: String, tools: [String] = [], environment: [String: String]
    ) -> [String] {
        ["/usr/bin/env", "-i"] + environment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }
            + arguments(executable: executable, choice: choice, system: system, tools: tools)
    }

    /// Asked before any prompt: the account and models, the MCP servers loaded, and the settings sources applied.
    /// `served`: the MCP servers Aegis serves itself over the control channel.
    public static func handshake(served: Bool = false) -> Data {
        let initialize = served ? #","sdkMcpServers":["\#(ClaudeTools.server)"]"# : ""
        return Data("""
        {"type":"control_request","request_id":"aegis-init","request":{"subtype":"initialize"\(initialize)}}
        {"type":"control_request","request_id":"aegis-mcp","request":{"subtype":"mcp_status"}}
        {"type":"control_request","request_id":"aegis-settings","request":{"subtype":"get_settings"}}

        """.utf8)
    }

    /// Aegis's answer to one of Claude Code's MCP messages.
    public static func mcpResponse(requestID: String, _ message: Data) -> Data {
        line(["type": "control_response", "response": [
            "subtype": "success", "request_id": requestID,
            "response": ["mcp_response": (try? JSONSerialization.jsonObject(with: message)) ?? [String: Any]()],
        ]])
    }

    /// Refuses any other request Claude Code makes of Aegis, such as permission to use a tool.
    public static func controlError(requestID: String) -> Data {
        line(["type": "control_response", "response": ["subtype": "error", "request_id": requestID, "error": "Not available"]])
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// The system prompt for a hand-off; its instructions travel in the message (`CloudHandOff.planPrompt`).
    public static let handOffSystem = "You answer for Aegis, a private assistant on the owner's Mac. Follow the instructions at the top "
        + "of the owner's message."

    /// One owner turn on Claude Code's input.
    public static func prompt(_ text: String) -> Data {
        struct Message: Encodable {
            let role = "user"
            let content: String
        }
        struct Input: Encodable {
            let type = "user"
            let message: Message
        }
        var data = (try? JSONEncoder().encode(Input(message: Message(content: text)))) ?? Data()
        data.append(0x0A)
        return data
    }

    /// How a run ended. `failed` and `refused` carry codes, never text.
    public enum Outcome: Equatable, Sendable {
        case answer(text: String, model: String)
        case signedOut
        case limit(resets: Date?)
        case declined
        /// Something is active that Aegis didn't ask for: a tool, MCP server, plugin, setting or API key.
        case refused([String])
        case failed(String)
    }

    /// Claude Code's output, read as it arrives and never kept beyond the reply.
    public struct Session: Sendable {
        public enum Event: Equatable, Sendable {
            /// The handshake passed: the prompt may go.
            case ready([Model])
            /// A piece of the reply as it's written.
            case text(String)
            /// Claude Code's MCP message for Aegis's own server, to answer with `mcpResponse`.
            case mcp(requestID: String, message: Data)
            /// Any other request of Aegis, to refuse with `controlError`.
            case denied(requestID: String)
            case finished(Outcome)
        }

        /// The longest single event, and the longest reply, in characters.
        public static let maxLine = 4 << 20
        public static let maxReply = 64000

        private let servers: Set<String>
        private let tools: Set<String>
        private var buffer = Data()
        private var pending: Set<String> = ["aegis-init", "aegis-mcp", "aegis-settings"]
        private var models: [Model] = []
        private var model = ""
        private var configured = false
        private var typed = 0
        private var lastError: String?
        private var limited = false
        private var resets: Date?
        public private(set) var finished = false

        /// `servers`: the MCP servers Aegis serves itself; `tools`: their tools' full names.
        public init(servers: Set<String> = [], tools: Set<String> = []) {
            self.servers = servers
            self.tools = tools
        }

        public mutating func feed(_ data: Data) -> [Event] {
            guard !finished else { return [] }
            buffer.append(data)
            var events: [Event] = []
            while !finished, let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex ..< newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                if let event = handle(line) {
                    events.append(event)
                }
            }
            if !finished, buffer.count > Self.maxLine {
                events.append(finish(.failed("line_too_long")))
            }
            return events
        }

        private mutating func handle(_ line: Data) -> Event? {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
            switch object["type"] as? String {
            case "control_response":
                return control(dictionary(object["response"]))
            case "control_request":
                guard let id = object["request_id"] as? String else { return nil }
                let request = dictionary(object["request"])
                guard request["subtype"] as? String == "mcp_message", let server = request["server_name"] as? String,
                      servers.contains(server), let message = request["message"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: message)
                else { return .denied(requestID: id) }
                return .mcp(requestID: id, message: data)
            case "system" where object["subtype"] as? String == "init":
                return configuration(object)
            case "stream_event":
                return delta(dictionary(object["event"]))
            case "rate_limit_event":
                let info = dictionary(object["rate_limit_info"])
                if info["status"] as? String == "rejected" {
                    limited = true
                    resets = number(info["resetsAt"]).map(Date.init(timeIntervalSince1970:)) ?? resets
                }
                return nil
            case "assistant":
                lastError = object["error"] as? String ?? lastError
                return nil
            case "result":
                return result(object)
            default:
                return nil
            }
        }

        private mutating func control(_ response: [String: Any]) -> Event? {
            guard let id = response["request_id"] as? String, pending.remove(id) != nil else { return nil }
            guard response["subtype"] as? String == "success" else { return finish(.failed("handshake")) }
            // A missing or renamed field is refused, never read as empty.
            let body = dictionary(response["response"])
            switch id {
            case "aegis-init":
                guard let account = body["account"] as? [String: Any], let commands = array(body["commands"]),
                      let offered = array(body["models"])
                else { return finish(.refused(["schema"])) }
                guard account["apiProvider"] as? String == "firstParty" else { return finish(.refused(["provider"])) }
                if let key = account["apiKeySource"] as? String, key != "none" {
                    return finish(.refused(["api_key"]))
                }
                // A subscription sign-in names its plan; anything else isn't the owner's plan.
                guard let plan = (account["subscription"] ?? account["subscriptionType"]) as? String, !plan.isEmpty else {
                    return finish(.signedOut)
                }
                guard commands.isEmpty else { return finish(.refused(["commands"])) }
                models = offered.compactMap { item in
                    let entry = dictionary(item)
                    guard let value = entry["value"] as? String, Choice(model: value, effort: .medium).isValid else { return nil }
                    return Model(value: value, name: entry["displayName"] as? String ?? value)
                }
            case "aegis-mcp":
                guard let loaded = array(body["mcpServers"]) else { return finish(.refused(["schema"])) }
                guard only(loaded, sourced: false) else { return finish(.refused(["mcp_servers"])) }
            default:
                // Any settings source or setting, managed policy included, could add hooks or plugins.
                guard let sources = array(body["sources"]), let effective = body["effective"] as? [String: Any] else {
                    return finish(.refused(["schema"]))
                }
                guard sources.isEmpty, effective.isEmpty else { return finish(.refused(["settings"])) }
            }
            return pending.isEmpty ? .ready(models) : nil
        }

        /// Claude Code's own account of what it loaded, checked again as the turn starts.
        private mutating func configuration(_ object: [String: Any]) -> Event? {
            guard let tools = array(object["tools"]), let loaded = array(object["mcp_servers"]),
                  let plugins = array(object["plugins"]), let skills = array(object["skills"]),
                  let commands = array(object["slash_commands"]), let key = object["apiKeySource"] as? String
            else { return finish(.refused(["schema"])) }
            var problems: [String] = []
            if !tools.allSatisfy({ ($0 as? String).map(self.tools.contains) ?? false }) {
                problems.append("tools")
            }
            if !only(loaded, sourced: true) {
                problems.append("mcp_servers")
            }
            if plugins.contains(where: { !(dictionary($0)["source"] as? String ?? "").hasSuffix("@builtin") }) {
                problems.append("plugins")
            }
            if !skills.isEmpty {
                problems.append("skills")
            }
            if !commands.isEmpty {
                problems.append("commands")
            }
            if key != "none" {
                problems.append("api_key")
            }
            if !pending.isEmpty {
                problems.append("order")
            }
            guard problems.isEmpty else { return finish(.refused(problems)) }
            model = object["model"] as? String ?? ""
            configured = true
            return nil
        }

        /// Only Aegis's own servers, served over the control channel. Claude Code's `init` report names each server's
        /// source; its status report may not yet.
        private func only(_ loaded: [Any], sourced: Bool) -> Bool {
            loaded.allSatisfy { item in
                let entry = dictionary(item)
                let source = entry["source"] as? String
                return (entry["name"] as? String).map(servers.contains) == true && (sourced ? source == "sdk" : (source ?? "sdk") == "sdk")
            }
        }

        private mutating func delta(_ event: [String: Any]) -> Event? {
            let delta = dictionary(event["delta"])
            guard configured, event["type"] as? String == "content_block_delta", delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, typed < Self.maxReply
            else { return nil }
            let piece = String(text.prefix(Self.maxReply - typed))
            typed += piece.count
            return .text(piece)
        }

        private mutating func result(_ object: [String: Any]) -> Event {
            guard configured else { return finish(.failed("no_init")) }
            guard truth(object["is_error"]) else {
                if object["stop_reason"] as? String == "refusal" {
                    return finish(.declined)
                }
                let text = (object["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return finish(.failed("empty")) }
                return finish(.answer(text: String(text.prefix(Self.maxReply)), model: model))
            }
            switch lastError {
            case "authentication_failed": return finish(.signedOut)
            case "rate_limit", "billing_error": return finish(.limit(resets: resets))
            default: return finish(limited ? .limit(resets: resets) : .failed(lastError ?? "error"))
            }
        }

        private mutating func finish(_ outcome: Outcome) -> Event {
            finished = true
            buffer = Data()
            return .finished(outcome)
        }
    }
}

/// JSONSerialization hands back Foundation types that differ between macOS and Linux.
private func dictionary(_ value: Any?) -> [String: Any] {
    value as? [String: Any] ?? [:]
}

private func array(_ value: Any?) -> [Any]? {
    value as? [Any]
}

private func truth(_ value: Any?) -> Bool {
    (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
}

private func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue ?? (value as? Double)
}
