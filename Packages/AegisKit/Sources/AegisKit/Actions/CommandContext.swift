import Foundation

/// The owner's follow-up to their own last command (#49): "open the other one", "the second one", "again",
/// "close it", "show it in Finder", "do the same for X".
public enum FollowUp: Sendable, Equatable {
    /// Another of the matches Aegis found.
    case other
    /// A match by its place, from 1; -1 is the last.
    case pick(Int)
    case again
    case close
    case reveal
    /// The same words with the thing they named swapped for this.
    case sameFor(String)

    public static func parse(_ text: String) -> FollowUp? {
        let line = ActionCommand.cleaned(text).lowercased().replacingOccurrences(of: "’", with: "'")
        let lead = #"^(?:no,? |nope,? |sorry,? )?(?:open |try |show me |play |use |pick |give me |i meant |i mean |go with )?"#
        if line.range(
            of: lead + #"(?:the )?other (?:one|file|match|app)$|^(?:not that one|wrong one|that's the wrong one)$"#,
            options: .regularExpression
        ) != nil {
            return .other
        }
        let places = [
            "first": 1,
            "1st": 1,
            "second": 2,
            "2nd": 2,
            "third": 3,
            "3rd": 3,
            "fourth": 4,
            "4th": 4,
            "fifth": 5,
            "5th": 5,
            "last": -1,
        ]
        if let word = ActionCommand.capture(
            lead + #"(?:the )?(first|1st|second|2nd|third|3rd|fourth|4th|fifth|5th|last) (?:one|file|match|app)$"#,
            line
        ),
            let place = places[word]
        {
            return .pick(place)
        }
        if let number = ActionCommand.capture(#"^(?:number|option) ([1-5])$"#, line).flatMap(Int.init) {
            return .pick(number)
        }
        if line.range(
            of: #"^(?:(?:do|run|open|play) )?(?:it|that|this) again$|^again$|^one more time$|^repeat that$|^same again$"#,
            options: .regularExpression
        ) != nil {
            return .again
        }
        if line
            .range(of: #"^(?:close|quit|exit)(?: it| that| this)(?: down)?$|^shut (?:it|that) down$"#, options: .regularExpression) != nil
        {
            return .close
        }
        if line.range(
            of: #"^(?:show|reveal|find) (?:it|that|this)(?: file| folder)? in (?:the )?finder$|^where is (?:it|that)(?: saved)?$"#,
            options: .regularExpression
        ) != nil {
            return .reveal
        }
        let same = #"^(?:and )?(?:do the same(?: thing)?|same(?: thing)?|do (?:it|that)) (?:for|with|to) (.+)$"#
        return ActionCommand.capture(same, ActionCommand.cleaned(text)).map(FollowUp.sameFor)
    }
}

/// What a follow-up can refer back to (#49): the owner's own last command, what Aegis did and the other matches it
/// found. It holds only the owner's words and Aegis's own results, never collected content.
public struct CommandContext: Sendable, Equatable {
    /// As long as the conversation's memory.
    public static let lifetime = Chat.memory

    public let words: String
    /// What was done or proposed; nil for a message, which has its own path.
    public var command: ActionCommand?
    /// The part of `words` that named the thing ("my Swiss trip plan"), for "do the same for X".
    public let target: String?
    /// Every match, best first, when there was a choice (files, apps).
    public let candidates: [ActionCommand]
    public var at: Date

    public init(words: String, command: ActionCommand?, target: String? = nil, candidates: [ActionCommand] = [], at: Date) {
        self.words = words
        self.command = command
        self.target = target ?? command.flatMap { Self.target($0, in: words) }
        self.candidates = candidates
        self.at = at
    }

    public func isFresh(at now: Date) -> Bool {
        now.timeIntervalSince(at) < Self.lifetime
    }

    /// What a follow-up comes to.
    public enum Resolution: Sendable, Equatable {
        /// Propose or run this, through the policy like any request.
        case run(ActionCommand)
        /// Ask these owner's words again, through the usual path.
        case ask(String)
        /// Nothing to do; say why.
        case say(String)
    }

    public func resolve(_ followUp: FollowUp) -> Resolution {
        let matches = candidates.isEmpty ? command.map { [$0] } ?? [] : candidates
        switch followUp {
        case .other:
            guard matches.count > 1 else { return .say("That was the only one I found.") }
            let index = command.flatMap { matches.firstIndex(of: $0) } ?? 0
            return .run(matches[(index + 1) % matches.count])
        case let .pick(place):
            let index = place < 0 ? matches.count - 1 : place - 1
            guard matches.indices.contains(index) else {
                return .say(matches.count == 1 ? "I only found one." : "I only found \(matches.count).")
            }
            return .run(matches[index])
        case .again:
            return command.map(Resolution.run) ?? .ask(words)
        case .close:
            return close()
        case .reveal:
            switch command {
            case let .openFile(path), let .automate(.finderReveal, path): return .run(.automate(.finderReveal, argument: path))
            default: return .say("That isn't a file or folder.")
            }
        case let .sameFor(thing):
            guard let target, let range = words.range(of: target, options: .caseInsensitive) else {
                return .say("I'm not sure what to swap. Say it in full.")
            }
            return .ask(words.replacingCharacters(in: range, with: thing))
        }
    }

    private func close() -> Resolution {
        switch command {
        case let .openApp(name): .run(.quitApp(name: name))
        case .automate(.musicPlay, _), .automate(.musicPause, _), .automate(.musicNext, _), .automate(.musicPrevious, _),
             .automate(.musicPlaylist, _): .run(.quitApp(name: "Music"))
        case .automate(.notesNewNote, _): .run(.quitApp(name: "Notes"))
        case .automate(.mapsDirections, _), .automate(.mapsSearch, _): .run(.quitApp(name: "Maps"))
        case .automate(.settingsPage, _): .run(.quitApp(name: "System Settings"))
        case .openFile, .findFile: .say("I can't close one file yet: press ⌘W in it.")
        case .openWebsite, .automate(.safariNewTab, _): .say("I can't close a tab yet: press ⌘W in it.")
        default: .say("There's nothing there for me to close.")
        }
    }

    /// The thing a command named, as the owner said it, when it's in their words.
    static func target(_ command: ActionCommand, in words: String) -> String? {
        let named: String? = switch command {
        case let .findFile(name, _), let .openApp(name), let .runShortcut(name): name
        case let .openWebsite(url): ActionCommand.bare(url)
        case let .automate(.musicPlaylist, name), let .automate(.notesNewNote, name), let .automate(.mapsDirections, name),
             let .automate(.mapsSearch, name), let .automate(.safariNewTab, name): ActionCommand.bare(name)
        default: nil
        }
        guard let named, !named.isEmpty, words.range(of: named, options: .caseInsensitive) != nil else { return nil }
        return named
    }
}
