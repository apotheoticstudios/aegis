import AegisKit
import AppKit
import Foundation

/// Files by name and the app automation catalogue (ADR-0031, #43).
extension PanelModel {
    /// The file or folder the owner named, as a step: open it, or show it in Finder.
    static func found(_ name: String, reveal: Bool) async -> ActionCommand? {
        guard let path = await file(named: name) else { return nil }
        return reveal ? .automate(.finderReveal, argument: path) : .openFile(path: path)
    }

    /// A file or folder in the owner's home folder by the name they said: a well-known folder, or else the Spotlight
    /// match used most recently, an exact name first. Spotlight searches names only, never contents; Library is
    /// allowed (owner's choice), hidden folders and programs aren't.
    static func file(named spoken: String) async -> String? {
        let wanted = FileName(spoken)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let known = wanted.known {
            return known.isEmpty ? home.path : home.appendingPathComponent(known).path
        }
        // App tests run inside Aegis: they never search the owner's files.
        let pattern = wanted.name.replacingOccurrences(of: #"[*?]"#, with: "", options: .regularExpression)
        guard !WorldSidecar.isTestHost, !pattern.isEmpty else { return nil }
        let inside = home.path + "/"
        let matches = await FileSearch().run(NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*" + pattern + "*"))
            .filter { match in
                let url = URL(fileURLWithPath: match.path).resolvingSymlinksInPath()
                guard url.path.hasPrefix(inside),
                      !url.path.dropFirst(inside.count).split(separator: "/").contains(where: { $0.hasPrefix(".") })
                else { return false }
                var folder: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &folder)
                // A program without an ending would run in Terminal when opened.
                guard folder.boolValue || !FileManager.default.isExecutableFile(atPath: url.path) else { return false }
                return wanted.folder ? folder.boolValue
                    : wanted.extensions.isEmpty || wanted.extensions.contains(url.pathExtension.lowercased())
            }
        let exact = { (path: String) -> Int in
            let url = URL(fileURLWithPath: path)
            return [url.lastPathComponent, url.deletingPathExtension().lastPathComponent]
                .contains { $0.caseInsensitiveCompare(wanted.name) == .orderedSame } ? 1 : 0
        }
        return matches.max { (exact($0.path), $0.used) < (exact($1.path), $1.used) }?.path
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
        guard let script = scripts[entry] else { return (false, "That's not something I can do.") }
        let app = entry == .notesNewNote ? "Notes" : entry == .safariNewTab ? "Safari" : "Music"
        guard await osascript(script, argument.isEmpty ? [] : [argument]) else {
            return (
                false,
                entry == .musicPlaylist ? "Music couldn't play a playlist called “\(argument)”."
                    : "\(app) didn't do that. Check that Aegis may control \(app) in Privacy & Security › Automation."
            )
        }
        let said = switch entry {
        case .musicPlay: "Playing."
        case .musicPause: "Paused."
        case .musicNext: "Next song."
        case .musicPrevious: "Previous song."
        case .musicPlaylist: "Playing “\(argument)”."
        case .notesNewNote: "Done. There's a new note called “\(argument)”."
        default: "Opening " + (URL(string: argument)?.host() ?? argument) + " in a new Safari tab."
        }
        return (true, said)
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
