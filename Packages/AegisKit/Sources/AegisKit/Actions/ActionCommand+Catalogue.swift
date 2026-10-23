import Foundation

/// The app automation catalogue and files by name (ADR-0031, #43), from the owner's own words.
extension ActionCommand {
    /// File-like endings that aren't websites ("Budget.xlsx").
    static let fileEndings: Set<String> = [
        "app", "md", "zip", "mov", "py", "sh", "pdf", "txt", "rtf", "doc", "docx", "xls", "xlsx", "csv", "pages", "numbers",
        "key", "ppt", "pptx", "jpg", "jpeg", "png", "heic", "gif", "mp3", "mp4", "m4a", "json",
    ]

    private static let music: [(String, AppAutomation)] = [
        (#"^(?:play|resume|start|unpause)(?: the| my| some)? music$|^resume$"#, .musicPlay),
        (#"^(?:pause|stop)(?: the| my)? (?:music|song)$|^pause$"#, .musicPause),
        (#"^(?:play |skip to )?(?:the )?next (?:song|track)$|^skip(?: this| the)? (?:song|track)$"#, .musicNext),
        (#"^(?:play |go back to )?(?:the )?(?:previous|last) (?:song|track)$|^go back a (?:song|track)$"#, .musicPrevious),
    ]

    /// The app automation catalogue and files by name (#43).
    static func catalogue(_ line: String) -> ActionCommand? {
        if let command = system(line) {
            return command
        }
        let verbs = #"^(?:open|load|go to|visit|pull up|bring up)(?: up)? (.+?) in (?:a )?new (?:safari )?tab(?: in safari)?$"#
        if let address = capture(verbs, line).flatMap(website) {
            return .automate(.safariNewTab, argument: address)
        }
        if let name = capture(#"^(?:show|reveal|find|locate)(?: me)? (.+?) in (?:the )?finder$"#, line) {
            return .findFile(name: name, reveal: true)
        }
        let note = #"^(?:(?:make|create|add|start|take)(?: me)? (?:a )?(?:new )?note (?:called|named|titled)|"#
            + #"new note(?: called| named| titled)?:?) (.+)$"#
        if let title = capture(note, line)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' ")), !title.isEmpty {
            return .automate(.notesNewNote, argument: title)
        }
        if let entry = music.first(where: { line.range(of: $0.0, options: [.regularExpression, .caseInsensitive]) != nil })?.1 {
            return .automate(entry, argument: "")
        }
        if let name = capture(#"^play (?:my |the )?(.+?) playlist$"#, line)
            ?? capture(#"^play (?:the )?playlist (?:called |named )?(.+)$"#, line)
        {
            return .automate(.musicPlaylist, argument: name)
        }
        let kinds = #"folder|directory|files?|spreadsheet|sheet|document|doc|presentation|deck|slides|pdf|photo|picture|image|video"#
        if let name = capture(#"^(?:open|show me|bring up|pull up)(?: up)? (.+ (?:"# + kinds + #"))$"#, line) {
            return .findFile(name: name, reveal: false)
        }
        return nil
    }

    /// An address without its scheme: "apple.com/store".
    static func bare(_ url: String) -> String {
        url.replacingOccurrences(of: #"^[a-z]+://"#, with: "", options: .regularExpression)
    }
}

/// What the owner called a file or folder, split into its name and the kind they said (#43): "my Downloads folder",
/// "the Budget spreadsheet". The panel searches the home folder by this name; it never reads what's inside a file.
public struct FileName: Sendable, Equatable {
    public let name: String
    /// Endings the kind word allows ("spreadsheet": numbers, xlsx…); empty for any file.
    public let extensions: Set<String>
    public let folder: Bool
    /// A well-known folder's place in the home folder: "Downloads", or "" for the home folder itself.
    public let known: String?

    private static let kinds: [(String, Set<String>)] = [
        ("folders?|directory", []), ("files?", []),
        ("spreadsheets?|sheets?", ["numbers", "xlsx", "xls", "csv"]),
        ("documents?|docs?", ["pages", "docx", "doc", "rtf", "txt", "md", "pdf"]),
        ("presentations?|decks?|slides?|keynotes?", ["key", "pptx", "ppt"]),
        ("pdfs?", ["pdf"]),
        ("photos?|pictures?|images?", ["jpg", "jpeg", "png", "heic", "gif", "tiff"]),
        ("videos?|movies?", ["mov", "mp4", "m4v"]),
    ]

    private static let knownFolders = [
        "home": "", "downloads": "Downloads", "documents": "Documents", "desktop": "Desktop",
        "pictures": "Pictures", "photos": "Pictures", "movies": "Movies", "videos": "Movies", "music": "Music",
        "public": "Public", "icloud": "Library/Mobile Documents/com~apple~CloudDocs",
        "icloud drive": "Library/Mobile Documents/com~apple~CloudDocs",
    ]

    public init(_ spoken: String) {
        var name = spoken.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"^(?:my|the|our) "#, with: "", options: [.regularExpression, .caseInsensitive])
        var extensions: Set<String> = []
        var folder = false
        var kindSaid = false
        for (index, (words, endings)) in Self.kinds.enumerated() {
            guard let range = name.range(of: #"\s+(?:"# + words + #")$"#, options: [.regularExpression, .caseInsensitive]) else {
                continue
            }
            name.removeSubrange(range)
            extensions = endings
            folder = index == 0
            kindSaid = true
            break
        }
        self.name = name
        self.extensions = extensions
        self.folder = folder
        known = folder || !kindSaid ? Self.knownFolders[name.lowercased()] : nil
    }
}

public extension AppAutomation {
    /// The card's question: "Pause the music?", "Make a note called “Groceries”?".
    func summary(_ argument: String) -> String {
        switch self {
        case .musicPlay: "Play music?"
        case .musicPause: "Pause the music?"
        case .musicNext: "Skip to the next song?"
        case .musicPrevious: "Go back a song?"
        case .musicPlaylist: "Play the playlist “\(argument)”?"
        case .notesNewNote: "Make a note called “\(argument)”?"
        case .safariNewTab: "Open " + ActionCommand.bare(argument) + " in a new Safari tab?"
        case .finderReveal: "Show “" + URL(fileURLWithPath: argument).lastPathComponent + "” in Finder?"
        case .mapsDirections: "Get directions to “\(argument)” in Maps?"
        case .mapsSearch: "Search Maps for “\(argument)”?"
        case .settingsPage: "Open \(SettingsPage.page(argument)?.name ?? argument) settings?"
        case .volumeSet: "Set the volume to \(argument)%?"
        case .volumeUp: "Turn the volume up?"
        case .volumeDown: "Turn the volume down?"
        case .mute: "Mute the sound?"
        case .unmute: "Unmute the sound?"
        case .darkMode: "Turn on dark mode?"
        case .lightMode: "Switch to light mode?"
        }
    }
}
