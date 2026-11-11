import Foundation

/// What Claude may ask Aegis to do (ADR-0038 §5–6, the owner's choice of pure C): typed tools, each turned into the
/// same `ActionCommand` Aegis builds from the owner's own words, so the app's resolver, `ActionPolicy`, cards and
/// action log treat it exactly as they treat the owner's commands. No raw payloads, no addresses but http(s), no
/// file paths, and nothing that approves a card.
public extension ClaudeTools {
    enum Action: Equatable, Sendable {
        case command(ActionCommand)
        /// Always a card that sends only after the owner's two confirmations.
        case message(to: String, text: String, channel: ActionMessageChannel)
        /// One card listing the steps; one approval runs them in order.
        case plan([ActionCommand])
    }

    /// Catalogue entries Claude may use: none that take a path or an address.
    static let controls: [AppAutomation] = AppAutomation.allCases.filter { ![.finderReveal, .safariNewTab].contains($0) }

    enum ActionTool: String, CaseIterable, Sendable {
        case openApp = "open_app", openWebsite = "open_website", openFile = "open_file", runShortcut = "run_shortcut"
        case quitApp = "quit_app", control, addReminder = "add_reminder", addEvent = "add_event"
        case sendMessage = "send_message", proposePlan = "propose_plan"

        public var fullName: String {
            "mcp__\(ClaudeTools.server)__\(rawValue)"
        }

        var summary: String {
            switch self {
            case .openApp: "Open an app on the owner's Mac by its name."
            case .openWebsite: "Open an http or https address in the owner's browser."
            case .openFile: "Open, or show in Finder, a file or folder in the owner's home folder, by its name."
            case .runShortcut: "Run one of the owner's shortcuts by its exact name."
            case .quitApp: "Quit an app by its name; it asks about unsaved work itself."
            case .control: "Control music, Notes, Maps, a Settings page, the volume or dark mode."
            case .addReminder: "Propose a reminder; the owner approves it on a card."
            case .addEvent: "Propose a calendar event; the owner approves it on a card."
            case .sendMessage: "Propose a text or email to one of the owner's contacts; it sends only after the owner confirms twice."
            case .proposePlan:
                "Propose up to \(CommandPlan.maxSteps) of the other actions (not messages) on one card; the owner approves "
                    + "them once. Use it whenever a request needs more than one action."
            }
        }

        var schema: [String: Any] {
            func text(_ description: String) -> [String: Any] {
                ["type": "string", "description": description]
            }
            let date = ["type": "string", "description": "ISO 8601 date and time, for example 2026-11-12T17:00:00+10:00"]
            let properties: [String: Any]
            var required: [String]
            switch self {
            case .openApp, .quitApp:
                properties = ["name": text("The app's name")]
                required = ["name"]
            case .openWebsite:
                properties = ["address": text("An http(s) address or a domain such as bom.gov.au")]
                required = ["address"]
            case .openFile:
                properties = ["name": text("The file or folder's name, never a path"), "reveal": ["type": "boolean"]]
                required = ["name"]
            case .runShortcut:
                properties = ["name": text("The shortcut's exact name")]
                required = ["name"]
            case .control:
                properties = [
                    "entry": ["type": "string", "enum": ClaudeTools.controls.map(\.rawValue)],
                    "argument": text("A playlist, note title, place, Settings page or volume 0–100, when the entry needs one"),
                ]
                required = ["entry"]
            case .addReminder:
                properties = ["title": text("What to remember"), "due": date]
                required = ["title"]
            case .addEvent:
                properties = ["title": text("The event's title"), "start": date, "end": date]
                required = ["title", "start", "end"]
            case .sendMessage:
                properties = [
                    "to": text("The contact's name"), "text": text("The message"),
                    "channel": ["type": "string", "enum": ["message", "email"]],
                ]
                required = ["to", "text"]
            case .proposePlan:
                let step: [String: Any] = [
                    "type": "object",
                    "properties": ["tool": ["type": "string"], "arguments": ["type": "object"]],
                    "required": ["tool", "arguments"],
                ]
                properties = ["steps": ["type": "array", "items": step, "minItems": 2, "maxItems": CommandPlan.maxSteps]]
                required = ["steps"]
            }
            return ["type": "object", "properties": properties, "required": required]
        }
    }

    /// The action a call asks for, or nil when its arguments aren't valid.
    static func action(_ tool: ActionTool, _ arguments: [String: Any]) -> Action? {
        switch tool {
        case .sendMessage:
            guard let to = field(arguments, "to", 80), let text = field(arguments, "text", 1000) else { return nil }
            let channel = ActionMessageChannel(rawValue: arguments["channel"] as? String ?? "message")
            return channel.map { .message(to: to, text: text, channel: $0) }
        case .proposePlan:
            guard let steps = arguments["steps"] as? [[String: Any]], (2 ... CommandPlan.maxSteps).contains(steps.count) else { return nil }
            let commands = steps.compactMap { step -> ActionCommand? in
                guard let name = step["tool"] as? String, let tool = ActionTool(rawValue: name) else { return nil }
                return command(tool, step["arguments"] as? [String: Any] ?? [:])
            }
            return commands.count == steps.count ? .plan(commands) : nil
        default:
            return command(tool, arguments).map(Action.command)
        }
    }

    /// One command; messages and plans are never steps.
    static func command(_ tool: ActionTool, _ arguments: [String: Any]) -> ActionCommand? {
        switch tool {
        case .openApp: return field(arguments, "name", 80).map(ActionCommand.openApp)
        case .quitApp: return field(arguments, "name", 80).map(ActionCommand.quitApp)
        case .runShortcut: return field(arguments, "name", CommandPlan.maxNameScalars).map(ActionCommand.runShortcut)
        case .openWebsite: return field(arguments, "address", 500).flatMap(ActionCommand.website).map(ActionCommand.openWebsite)
        case .openFile:
            guard let name = field(arguments, "name", 120), !name.contains("/"), !name.contains(":"), !name.hasPrefix("~"),
                  name != ".", name != ".."
            else { return nil }
            return .findFile(name: name, reveal: arguments["reveal"] as? Bool ?? false)
        case .control:
            guard let entry = (arguments["entry"] as? String).flatMap(AppAutomation.init(rawValue:)),
                  controls.contains(entry) else { return nil }
            let argument = arguments["argument"] == nil ? "" : field(arguments, "argument", 200)
            return argument.map { .automate(entry, argument: $0) }
        case .addReminder:
            guard let title = field(arguments, "title", 200) else { return nil }
            let due = arguments["due"].map { ($0 as? String).flatMap(Self.date) }
            return due == .some(nil) ? nil : .reminder(title: title, due: due ?? nil)
        case .addEvent:
            guard let title = field(arguments, "title", 200), let start = (arguments["start"] as? String).flatMap(date),
                  let end = (arguments["end"] as? String).flatMap(date), end > start, end.timeIntervalSince(start) <= 86400
            else { return nil }
            return .event(title: title, start: start, end: end)
        case .sendMessage, .proposePlan:
            return nil
        }
    }

    /// A trimmed string of at most `limit` characters with no control characters.
    private static func field(_ arguments: [String: Any], _ key: String, _ limit: Int) -> String? {
        guard let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.count <= limit, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return value
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
