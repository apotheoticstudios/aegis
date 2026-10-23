import Foundation

/// The one ability the local model picked for the owner's request (ADR-0031).
public struct CommandStep: Codable, Sendable, Hashable {
    public enum Ability: String, Codable, Sendable {
        case shortcut, website, app
    }

    public let ability: Ability
    /// A shortcut's exact name, an http(s) address, or an app's name.
    public let value: String

    public init(ability: Ability, value: String) {
        self.ability = ability
        self.value = value
    }

    public var command: ActionCommand {
        switch ability {
        case .shortcut: .runShortcut(name: value)
        case .website: .openWebsite(url: value)
        case .app: .openApp(name: value)
        }
    }
}

/// When no fixed phrase matched, the local model maps the owner's words to one ability from a closed catalogue
/// (ADR-0031). It never writes scripts or links of its own; its reply is checked before anything is proposed.
public enum CommandPlan {
    /// The most shortcut names sent with one request, and the longest name.
    public static let maxShortcuts = 200
    public static let maxNameScalars = 100

    /// Worth one model job: the line starts with a doing word ("run", "open", "turn on"…).
    public static func looksLikeCommand(_ text: String) -> Bool {
        let line = ActionCommand.cleaned(text)
        return line.count <= 160 && line.range(
            of: #"^(?:run|open|start|launch|go to|visit|take me to|pull up|bring up|load|play|turn|switch|kick off|begin|"#
                + #"trigger|activate|set|put on)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    public static func systemPrompt() -> String {
        """
        Pick at most one ability for the owner's request on their Mac. Reply with ONLY JSON:
        {"ability":"shortcut|website|app|none","value":"…"}
        - shortcut: run one of the owner's shortcuts. value is a name copied exactly from OWNER'S SHORTCUTS.
        - website: open a public website in the browser. value is its address, like www.example.com. Only sites you are sure of.
        - app: open a Mac app. value is the app's name, like Music.
        - none: anything else, including questions and anything about paying, buying, deleting or passwords.
        """
    }

    /// The owner's request, after their own shortcut names (the only list the model may pick from).
    public static func input(question: String, shortcuts: [String]) -> String {
        let names = shortcuts.isEmpty ? "none" : shortcuts.joined(separator: "; ")
        return "OWNER'S SHORTCUTS: " + names + "\nOWNER SAYS: " + question
    }

    /// The checked step, or nil for "none" and anything that doesn't pass: a shortcut must be one of the
    /// owner's (its exact name is used), a website a real http(s) address, an app a short name.
    public static func parse(_ reply: String, shortcuts: [String]) -> CommandStep? {
        guard let object = Briefing.extractJSON(reply),
              let ability = (object["ability"] as? String).flatMap(CommandStep.Ability.init),
              let value = (object["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        switch ability {
        case .shortcut:
            return shortcuts.first { $0.caseInsensitiveCompare(value) == .orderedSame }.map { CommandStep(ability: .shortcut, value: $0) }
        case .website:
            return ActionCommand.website(value).map { CommandStep(ability: .website, value: $0) }
        case .app:
            guard value.count <= 40, value.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\n\r")) == nil else { return nil }
            return CommandStep(ability: .app, value: value)
        }
    }
}
