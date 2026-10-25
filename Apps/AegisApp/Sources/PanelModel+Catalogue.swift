import AegisKit
import AppKit
import Foundation

/// Files by name and the app automation catalogue (ADR-0031, #43).
extension PanelModel {
    /// The file or folder the owner named, as a step: open it, or show it in Finder.
    static func found(_ name: String, reveal: Bool) async -> ActionCommand? {
        await foundAll(name, reveal: reveal).first
    }

    /// Every match, best first, for "the other one" (#49).
    static func foundAll(_ name: String, reveal: Bool) async -> [ActionCommand] {
        await files(named: name).map { reveal ? .automate(.finderReveal, argument: $0) : .openFile(path: $0) }
    }

    /// Files or folders in the owner's home folder by the name they said, best first (at most 10): a well-known folder,
    /// or else Spotlight's matches, exact names first, then the ones used most recently. Spotlight searches names only,
    /// never contents; Library is allowed (owner's choice), hidden folders and programs aren't.
    static func files(named spoken: String) async -> [String] {
        let wanted = FileName(spoken)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let known = wanted.known {
            return [openable(known.isEmpty ? home.path : home.appendingPathComponent(known).path, wanted: wanted, home: home.path)]
                .compactMap(\.self)
        }
        // App tests run inside Aegis: they never search the owner's files.
        let pattern = wanted.name.replacingOccurrences(of: #"[*?]"#, with: "", options: .regularExpression)
        guard !WorldSidecar.isTestHost, !pattern.isEmpty else { return [] }
        let matches = await FileSearch().run(NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*" + pattern + "*"))
            .compactMap { match in
                openable(match.path, wanted: wanted, home: home.path).map { (
                    path: $0,
                    name: URL(fileURLWithPath: match.path),
                    used: match.used
                ) }
            }
        let exact = { (url: URL) -> Int in
            [url.lastPathComponent, url.deletingPathExtension().lastPathComponent]
                .contains { $0.caseInsensitiveCompare(wanted.name) == .orderedSame } ? 1 : 0
        }
        var seen = Set<String>()
        return matches.sorted { (exact($0.name), $0.used) > (exact($1.name), $1.used) }.map(\.path)
            .filter { seen.insert($0).inserted }.prefix(10).map(\.self)
    }

    /// The real file or folder behind a path, with Finder aliases and symlinks followed, when Aegis may open it for
    /// this request: inside the home folder, not hidden, not a program, of the kind asked for, and allowed by the
    /// policy. The real path is what's logged and opened, never the link (#59).
    static func openable(_ path: String, wanted: FileName, home: String) -> String? {
        var url = URL(fileURLWithPath: path)
        for _ in 0 ..< 8 {
            let next = ((try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])) ?? url).resolvingSymlinksInPath()
            if next == url {
                break
            }
            url = next
        }
        let root = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        let real = url.path
        var folder: ObjCBool = false
        guard real == root || real.hasPrefix(root + "/"),
              !real.dropFirst(root.count).split(separator: "/").contains(where: { $0.hasPrefix(".") }),
              FileManager.default.fileExists(atPath: real, isDirectory: &folder),
              let kind = try? url.resourceValues(forKeys: [.isAliasFileKey, .isApplicationKey]),
              kind.isAliasFile != true, kind.isApplication != true,
              // A program without an ending would run in Terminal when opened.
              folder.boolValue || !FileManager.default.isExecutableFile(atPath: real),
              wanted.folder ? folder.boolValue : wanted.extensions.isEmpty || wanted.extensions.contains(url.pathExtension.lowercased())
        else { return nil }
        let request = ActionRequest(payload: .file(path: real, verb: .open), origin: .ownerTyped)
        return ActionPolicy.decision(for: request, settings: .init(panelIsOpen: true)).allowed ? real : nil
    }

    /// The catalogue's fixed scripts. An argument only ever arrives as `item 1 of argv`, never inside the script.
    /// Finder reveal needs no script: NSWorkspace selects the file in Finder.
    static let scripts: [AppAutomation: String] = [
        .musicPlay: #"tell application "Music" to play"#,
        .musicPause: #"tell application "Music" to pause"#,
        .musicNext: #"tell application "Music" to next track"#,
        .musicPrevious: #"tell application "Music" to previous track"#,
        .musicPlaylist: """
        on run argv
          tell application "Music" to play playlist (item 1 of argv)
        end run
        """,
        .notesNewNote: """
        on run argv
          tell application "Notes"
            activate
            set theNote to make new note with properties {name:item 1 of argv}
            try
              show theNote
            end try
          end tell
        end run
        """,
        .volumeSet: """
        on run argv
          set volume output volume ((item 1 of argv) as integer) without output muted
        end run
        """,
        .volumeUp: "set volume output volume ((output volume of (get volume settings)) + 10) without output muted",
        .volumeDown: "set volume output volume ((output volume of (get volume settings)) - 10)",
        .mute: "set volume with output muted",
        .unmute: "set volume without output muted",
        .darkMode: #"tell application "System Events" to tell appearance preferences to set dark mode to true"#,
        .lightMode: #"tell application "System Events" to tell appearance preferences to set dark mode to false"#,
        .safariNewTab: """
        on run argv
          tell application "Safari"
            activate
            if (count of windows) is 0 then
              make new document with properties {URL:item 1 of argv}
            else
              tell front window to set current tab to (make new tab with properties {URL:item 1 of argv})
            end if
          end tell
        end run
        """,
    ]

    /// Runs one catalogue entry: whether it worked, and what to say.
    static func automate(_ entry: AppAutomation, _ argument: String) async -> (Bool, String) {
        if entry == .finderReveal {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: argument)])
            return (true, "Showing “\(URL(fileURLWithPath: argument).lastPathComponent)” in Finder.")
        }
        if let link = link(entry, argument) {
            return NSWorkspace.shared.open(link) ? (true, said(entry, argument)) : (false, "I couldn't open that.")
        }
        guard let script = scripts[entry], entry != .volumeSet || Int(argument).map({ (0 ... 100).contains($0) }) == true else {
            return (false, "That's not something I can do.")
        }
        guard await osascript(script, argument.isEmpty ? [] : [argument]) else {
            let app = switch entry {
            case .notesNewNote: "Notes"
            case .safariNewTab: "Safari"
            case .darkMode, .lightMode: "System Events"
            default: "Music"
            }
            return (
                false,
                entry == .musicPlaylist ? "Music couldn't play a playlist called “\(argument)”."
                    : [.volumeSet, .volumeUp, .volumeDown, .mute, .unmute].contains(entry) ? "The volume didn't change."
                    : "\(app) didn't do that. Check that Aegis may control \(app) in Privacy & Security › Automation."
            )
        }
        return (true, said(entry, argument))
    }

    /// Maps and System Settings open by their documented links (#45); the owner's words only go in as an encoded value.
    static func link(_ entry: AppAutomation, _ argument: String) -> URL? {
        let value = argument.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
        return switch entry {
        case .mapsDirections: URL(string: "maps://?daddr=" + value)
        case .mapsSearch: URL(string: "maps://?q=" + value)
        case .settingsPage: SettingsPage.page(argument).flatMap { URL(string: "x-apple.systempreferences:" + $0.id) }
        default: nil
        }
    }

    /// What Aegis says once a catalogue entry has run.
    static func said(_ entry: AppAutomation, _ argument: String) -> String {
        switch entry {
        case .musicPlay: "Playing."
        case .musicPause: "Paused."
        case .musicNext: "Next song."
        case .musicPrevious: "Previous song."
        case .musicPlaylist: "Playing “\(argument)”."
        case .notesNewNote: "Done. There's a new note called “\(argument)”."
        case .mapsDirections: "Getting directions to \(argument) in Maps."
        case .mapsSearch: "Searching Maps for \(argument)."
        case .settingsPage: "Opening \(SettingsPage.page(argument)?.name ?? "") settings."
        case .volumeSet: "Volume \(argument)%."
        case .volumeUp: "Turned it up."
        case .volumeDown: "Turned it down."
        case .mute: "Muted."
        case .unmute: "Unmuted."
        case .darkMode: "Dark mode on."
        case .lightMode: "Light mode on."
        case .finderReveal: "Showing “\(URL(fileURLWithPath: argument).lastPathComponent)” in Finder."
        case .safariNewTab: "Opening " + (URL(string: argument)?.host() ?? argument) + " in a new Safari tab."
        }
    }

    /// Runs a fixed AppleScript with `osascript`; arguments arrive as `argv`, never inside the script. Whether it worked.
    static func osascript(_ script: String, _ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }
}

/// One Spotlight search by file name in the home folder; it gives up after three seconds.
@MainActor
private final class FileSearch: NSObject {
    private let query = NSMetadataQuery()
    private var continuation: CheckedContinuation<[(path: String, used: Date)], Never>?

    func run(_ predicate: NSPredicate) async -> [(path: String, used: Date)] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            NotificationCenter.default.addObserver(
                self, selector: #selector(gathered), name: .NSMetadataQueryDidFinishGathering, object: query
            )
            query.searchScopes = [NSMetadataQueryUserHomeScope]
            query.predicate = predicate
            guard query.start() else { return finish() }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.finish()
            }
        }
    }

    @objc private func gathered() {
        finish()
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        // The query stops here; NotificationCenter drops this observer when it's freed.
        query.stop()
        let found = (0 ..< query.resultCount).compactMap { index -> (path: String, used: Date)? in
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { return nil }
            let used = item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
                ?? item.value(forAttribute: NSMetadataItemContentModificationDateKey) as? Date ?? .distantPast
            return (path, used)
        }
        continuation.resume(returning: found)
    }
}
