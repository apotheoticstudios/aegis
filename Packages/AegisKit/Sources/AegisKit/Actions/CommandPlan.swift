import Foundation

/// The one ability the local model picked for the owner's request (ADR-0031).
public struct CommandStep: Codable, Sendable, Hashable {
    public enum Ability: String, Codable, Sendable {
        case shortcut, website, app
        /// A file or folder by the name the owner said, to open or to show in Finder (#43).
        case file, reveal
        /// The app automation catalogue (#43): Music, a new note, a new Safari tab.
        case play, pause, next, previous, playlist, note, tab
        /// Maps, a Settings page, volume and dark mode (#45).
        case directions, maps, settings, volume, mute, unmute, dark, light
    }

    public let ability: Ability
    /// A shortcut's exact name, an http(s) address, an app's, file's or playlist's name, a note's title, or "".
    public let value: String

    private static let automations: [Ability: AppAutomation] = [
        .play: .musicPlay, .pause: .musicPause, .next: .musicNext, .previous: .musicPrevious, .playlist: .musicPlaylist,
        .note: .notesNewNote, .tab: .safariNewTab, .directions: .mapsDirections, .maps: .mapsSearch, .settings: .settingsPage,
        .mute: .mute, .unmute: .unmute, .dark: .darkMode, .light: .lightMode,
    ]

    public init(ability: Ability, value: String) {
        self.ability = ability
        self.value = value
    }

    public var command: ActionCommand {
        if ability == .volume {
            return .automate(
                value == "up" ? .volumeUp : value == "down" ? .volumeDown : .volumeSet,
                argument: Int(value) == nil ? "" : value
            )
        }
        if let entry = Self.automations[ability] {
            return .automate(entry, argument: value)
        }
        return switch ability {
        case .shortcut: .runShortcut(name: value)
        case .website: .openWebsite(url: value)
        case .file, .reveal: .findFile(name: value, reveal: ability == .reveal)
        default: .openApp(name: value)
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
                + #"trigger|activate|set|put on|pause|resume|skip|reveal|mute|unmute|navigate|directions|get directions|louder|quieter)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    public static func systemPrompt() -> String {
        """
        Pick at most one ability for the owner's request on their Mac. Reply with ONLY JSON:
        {"ability":"shortcut|website|tab|app|file|reveal|play|pause|next|previous|playlist|note|directions|maps|settings|volume|mute|unmute|dark|light|none","value":"…"}
        - shortcut: run one of the owner's shortcuts. value is a name copied exactly from OWNER'S SHORTCUTS.
        - website: open a public website in the browser. value is its address, like www.example.com. Only sites you are sure of.
        - tab: the same in a new Safari tab, when the owner says Safari or a new tab.
        - app: open a Mac app. value is the app's name, like Music.
        - file: open a file or folder in the owner's home folder. value is its name as the owner said it, like Budget spreadsheet.
        - reveal: show a file or folder in Finder. value is its name, as for file.
        - play, pause, next, previous: control the Music app. value is "".
        - playlist: play a playlist in Music. value is its name as the owner said it.
        - note: make a new note in Notes. value is its title, in the owner's words.
        - directions: directions in Apple Maps. value is the place, in the owner's words.
        - maps: search Apple Maps. value is what to find, in the owner's words.
        - settings: open a System Settings page; it never changes a setting. value is one of: \(SettingsPage.pages.map(\.key).joined(separator: ", ")).
        - volume: the Mac's volume. value is up, down, or a number from 0 to 100.
        - mute, unmute: the Mac's sound. value is "".
        - dark, light: dark or light mode. value is "".
        - none: anything else, including questions and anything about paying, buying, deleting or passwords.
        """
    }

    /// The owner's request, after their own shortcut names (the only list the model may pick from).
    public static func input(question: String, shortcuts: [String]) -> String {
        let names = shortcuts.isEmpty ? "none" : shortcuts.joined(separator: "; ")
        return "OWNER'S SHORTCUTS: " + names + "\nOWNER SAYS: " + question
    }

    /// The checked step, or nil for "none" and anything that doesn't pass: a shortcut must be one of the
    /// owner's (its exact name is used), a website a real http(s) address, a name short with no path, a title one line.
    public static func parse(_ reply: String, shortcuts: [String]) -> CommandStep? {
        guard let object = Briefing.extractJSON(reply),
              let ability = (object["ability"] as? String).flatMap(CommandStep.Ability.init)
        else { return nil }
        let value = ((object["value"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch ability {
        case .play, .pause, .next, .previous, .mute, .unmute, .dark, .light:
            return CommandStep(ability: ability, value: "")
        case .settings:
            return SettingsPage.key(value).map { CommandStep(ability: .settings, value: $0) }
        case .volume:
            if value == "up" || value == "down" {
                return CommandStep(ability: .volume, value: value)
            }
            return Int(value).flatMap { (0 ... 100).contains($0) ? CommandStep(ability: .volume, value: String($0)) : nil }
        case .shortcut:
            return shortcuts.first { $0.caseInsensitiveCompare(value) == .orderedSame }.map { CommandStep(ability: .shortcut, value: $0) }
        case .website, .tab:
            return ActionCommand.website(value).map { CommandStep(ability: ability, value: $0) }
        case .note, .directions, .maps:
            guard !value.isEmpty, value.count <= 100, value.rangeOfCharacter(from: .newlines) == nil else { return nil }
            return CommandStep(ability: ability, value: value)
        case .app, .file, .reveal, .playlist:
            // Files are found by name in the home folder, never by a path the model wrote.
            guard !value.isEmpty, value.count <= 60, value.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\n\r")) == nil
            else { return nil }
            return CommandStep(ability: ability, value: value)
        }
    }
}
