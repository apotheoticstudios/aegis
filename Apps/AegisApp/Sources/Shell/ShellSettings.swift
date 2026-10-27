import Foundation

/// The one macOS setting AegisShell changes so far: the Dock's auto-hide (the menu bar stays macOS's own). Read from
/// the Dock's preferences; set through System Events, which animates the Dock away and back like System Settings.
@MainActor
protocol ShellDock {
    /// The current setting; nil when it can't be read.
    func autohide() -> Bool?
    /// Sets it; whether that worked.
    func set(autohide: Bool) async -> Bool
    /// The same, waiting for it, for when Aegis is quitting.
    func setNow(autohide: Bool) -> Bool
}

/// What AegisShell changes is saved before it changes it and put back on disengage, on quit, and on the next launch
/// after a crash (ADR-0033). The saved file is written before anything changes and removed only once the restore
/// worked, so a failure is retried at the next launch.
@MainActor
final class ShellSettings {
    struct Saved: Codable, Equatable {
        var dockAutohide: Bool
    }

    private let dock: any ShellDock
    private let file: URL

    init(dock: any ShellDock, file: URL) {
        self.dock = dock
        self.file = file
    }

    var saved: Saved? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }

    /// Saves the Dock's setting, then hides it. Whether the Dock is hidden.
    func apply() async -> Bool {
        // Engaged again before a restore went through: the first saving is the owner's own setting.
        if saved == nil {
            guard let current = dock.autohide(), let data = try? JSONEncoder().encode(Saved(dockAutohide: current)) else { return false }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                return false
            }
        }
        return dock.autohide() == true ? true : await dock.set(autohide: true)
    }

    /// Puts back what was saved. Whether macOS is as it was.
    @discardableResult
    func restore() async -> Bool {
        guard let saved else { return true }
        if dock.autohide() != saved.dockAutohide {
            guard await dock.set(autohide: saved.dockAutohide) else { return false }
        }
        try? FileManager.default.removeItem(at: file)
        return true
    }

    /// The same, before Aegis quits.
    @discardableResult
    func restoreNow() -> Bool {
        guard let saved else { return true }
        guard dock.autohide() == saved.dockAutohide || dock.setNow(autohide: saved.dockAutohide) else { return false }
        try? FileManager.default.removeItem(at: file)
        return true
    }
}

/// The real Dock.
struct SystemDock: ShellDock {
    private static let script = """
    on run argv
        tell application "System Events" to set autohide of dock preferences to (item 1 of argv is "true")
    end run
    """

    func autohide() -> Bool? {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        // Never set means off.
        return CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool ?? false
    }

    func set(autohide: Bool) async -> Bool {
        await PanelModel.osascript(Self.script, [autohide ? "true" : "false"])
    }

    func setNow(autohide: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.script, autohide ? "true" : "false"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
