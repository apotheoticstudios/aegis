import AppKit

/// One of the two macOS settings AegisShell changes: the Dock's auto-hide. Read from the Dock's preferences; set
/// through System Events, which animates the Dock away and back like System Settings.
@MainActor
protocol ShellDock {
    /// The current setting; nil when it can't be read.
    func autohide() -> Bool?
    /// Sets it; whether that worked.
    func set(autohide: Bool) async -> Bool
    /// The same, waiting for it, for when Aegis is quitting.
    func setNow(autohide: Bool) -> Bool
}

/// The other: the wallpaper of each desktop (Space). macOS colours the see-through menu bar's items for the wallpaper,
/// not for the windows behind them, so a dark one while engaged keeps them light and the whole bar dark over AegisShell's
/// desktop. macOS only changes the desktop showing, so each desktop is darkened when shown and marked to tell it apart.
@MainActor
protocol ShellWallpaper {
    /// Each display's picture on the desktop showing; nil when one can't be read.
    func current() -> [ShellSettings.Wallpaper]?
    /// Whether the desktop showing already has AegisShell's picture.
    func darkened() -> Bool
    /// Puts AegisShell's dark picture on the desktop showing; whether that worked.
    func darken() -> Bool
    /// Puts the saved pictures back on the desktop showing, where AegisShell's still shows; whether that worked.
    func restore(_ pictures: [ShellSettings.Wallpaper]) -> Bool
    /// Marks the desktop showing, to know it again.
    func mark() -> UUID
    /// Whether the desktop showing is the one marked.
    func isShowing(_ mark: UUID) -> Bool
    /// Whether the mark is still there (a crash takes them all).
    func isMarked(_ mark: UUID) -> Bool
    func unmark(_ mark: UUID)
}

/// What AegisShell changes is saved before it changes it and put back on disengage, on quit, and on the next launch
/// after a crash (ADR-0033). The saved file is written before anything changes and removed only once everything is
/// back, so a failure is retried at the next launch. Desktops other than the one showing are put back when next shown.
@MainActor
final class ShellSettings {
    struct Saved: Codable, Equatable {
        /// The owner's Dock setting; nil once it's back.
        var dockAutohide: Bool?
        /// Each desktop AegisShell darkened, in the order shown. Missing while none is.
        var spaces: [Space]?
    }

    /// A darkened desktop: its mark and its own pictures.
    struct Space: Codable, Equatable {
        let mark: UUID
        let pictures: [Wallpaper]
    }

    /// One display's picture and how it's shown.
    struct Wallpaper: Codable, Equatable {
        let display: UInt32
        let url: URL
        var scaling: UInt?
        var clipping: Bool?
        /// The fill colour: sRGB red, green, blue and alpha.
        var fill: [Double]?
    }

    private let dock: any ShellDock
    private let wallpaper: (any ShellWallpaper)?
    private let file: URL

    init(dock: any ShellDock, wallpaper: (any ShellWallpaper)? = nil, file: URL) {
        self.dock = dock
        self.wallpaper = wallpaper
        self.file = file
    }

    var saved: Saved? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }

    /// Saves the Dock's setting, then hides it, and darkens the desktop showing. Whether the Dock is hidden.
    func apply() async -> Bool {
        var state = saved ?? Saved()
        // Engaged again before a restore went through: the first saving is the owner's own setting.
        if state.dockAutohide == nil {
            guard let current = dock.autohide() else { return false }
            state.dockAutohide = current
            guard save(state) else { return false }
        }
        darkenShowingSpace()
        return dock.autohide() == true ? true : await dock.set(autohide: true)
    }

    /// While engaged, each desktop as it's shown: its pictures saved, then darkened. If either fails, the menu bar's
    /// strip still shows that desktop's wallpaper, so its items stay readable.
    func darkenShowingSpace() {
        guard let wallpaper, var state = saved, !wallpaper.darkened(), let pictures = wallpaper.current() else { return }
        let mark = wallpaper.mark()
        state.spaces = (state.spaces ?? []) + [Space(mark: mark, pictures: pictures)]
        guard save(state) else { return wallpaper.unmark(mark) }
        try? JSONEncoder().encode(pictures).write(to: last)
        _ = wallpaper.darken()
    }

    /// Puts back the Dock and the desktop showing. Whether those are as they were.
    @discardableResult
    func restore() async -> Bool {
        guard var state = saved else { return true }
        if let autohide = state.dockAutohide {
            if dock.autohide() != autohide {
                guard await dock.set(autohide: autohide) else { return false }
            }
            state.dockAutohide = nil
        }
        let back = restoringShowingSpace(&state)
        keep(state)
        return back
    }

    /// The same, before Aegis quits.
    @discardableResult
    func restoreNow() -> Bool {
        guard var state = saved else { return true }
        if let autohide = state.dockAutohide {
            guard dock.autohide() == autohide || dock.setNow(autohide: autohide) else { return false }
            state.dockAutohide = nil
        }
        let back = restoringShowingSpace(&state)
        keep(state)
        return back
    }

    /// After disengaging: a desktop AegisShell darkened gets its own wallpaper back when it's next shown.
    func restoreShownSpace() {
        var state = saved ?? Saved()
        guard state.dockAutohide == nil else { return }
        _ = restoringShowingSpace(&state)
        keep(state)
    }

    /// The desktop showing, if AegisShell darkened it: found by its mark. Whether it's back.
    private func restoringShowingSpace(_ state: inout Saved) -> Bool {
        guard let wallpaper, wallpaper.darkened() else { return true }
        var spaces = state.spaces ?? []
        // shortcut: after a crash the marks are gone and the first saved pictures go back, exact when every desktop had
        // the same wallpaper. Upgrade if owners lose per-desktop wallpapers that way.
        guard let index = spaces.firstIndex(where: { wallpaper.isShowing($0.mark) })
            ?? spaces.firstIndex(where: { !wallpaper.isMarked($0.mark) })
        else {
            // Left dark with no record of its own (by an earlier version, or a step missed): the first saved pictures,
            // still kept for their own desktop, or else the last AegisShell saved.
            let fallback = spaces.first?.pictures ?? (try? Data(contentsOf: last)).flatMap { try? JSONDecoder().decode(
                [Wallpaper].self,
                from: $0
            ) }
            return fallback.map(wallpaper.restore) ?? true
        }
        guard wallpaper.restore(spaces[index].pictures) else { return false }
        wallpaper.unmark(spaces[index].mark)
        spaces.remove(at: index)
        state.spaces = spaces.isEmpty ? nil : spaces
        return true
    }

    /// Writes what's still to put back, or removes the file once nothing is.
    private func keep(_ state: Saved) {
        if state == Saved() {
            try? FileManager.default.removeItem(at: file)
        } else {
            _ = save(state)
        }
    }

    /// The last pictures saved, kept after everything is back so a desktop left dark can still be put right.
    private var last: URL {
        file.deletingLastPathComponent().appendingPathComponent("shell-last-wallpaper.json")
    }

    private func save(_ state: Saved) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
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

/// The real wallpaper, through NSWorkspace.
@MainActor
final class SystemWallpaper: ShellWallpaper {
    /// Where AegisShell's dark picture is kept: one per theme, so macOS never shows a stale colour.
    private let folder: URL
    private static let prefix = "shell-wallpaper-"
    /// One invisible window left on each darkened desktop: it stays there, so `isOnActiveSpace` tells the desktop apart.
    private var marks: [UUID: NSWindow] = [:]

    init(folder: URL) {
        self.folder = folder
    }

    func darkened() -> Bool {
        NSScreen.screens.contains { NSWorkspace.shared.desktopImageURL(for: $0)?.lastPathComponent.hasPrefix(Self.prefix) == true }
    }

    func mark() -> UUID {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        // Not on all desktops: it stays on the one showing now.
        window.collectionBehavior = [.ignoresCycle, .stationary]
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.orderBack(nil)
        let mark = UUID()
        marks[mark] = window
        return mark
    }

    func isShowing(_ mark: UUID) -> Bool {
        marks[mark]?.isOnActiveSpace == true
    }

    func isMarked(_ mark: UUID) -> Bool {
        marks[mark] != nil
    }

    func unmark(_ mark: UUID) {
        marks.removeValue(forKey: mark)?.close()
    }

    func current() -> [ShellSettings.Wallpaper]? {
        let pictures = NSScreen.screens.map { screen -> ShellSettings.Wallpaper? in
            guard let display = Self.display(screen), let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            let fill = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB)
            return .init(
                display: display, url: url,
                scaling: (options[.imageScaling] as? NSNumber)?.uintValue,
                clipping: (options[.allowClipping] as? NSNumber)?.boolValue,
                fill: fill.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent].map(Double.init) }
            )
        }
        return pictures.contains(nil) ? nil : pictures.compactMap(\.self)
    }

    func darken() -> Bool {
        let theme = UserDefaults.aegis.string(forKey: HUDTheme.storeKey).flatMap(HUDTheme.init) ?? .arc
        let void = Self.color(theme.rgba(.void))
        let url = folder.appendingPathComponent(Self.prefix + theme.rawValue + "-\(Self.side).png")
        guard Self.write(void, to: url) else { return false }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue, .allowClipping: true,
            // macOS 27 paints its own blue round a picture it doesn't stretch; the fill keeps the whole wallpaper void.
            .fillColor: void,
        ]
        return NSScreen.screens.allSatisfy { (try? NSWorkspace.shared.setDesktopImageURL(url, for: $0, options: options)) != nil }
    }

    func restore(_ pictures: [ShellSettings.Wallpaper]) -> Bool {
        // shortcut: one mark per desktop of the main display; with "Displays have separate Spaces", another display's
        // desktops go back with the main display's. Upgrade if owners switch desktops per display.
        NSScreen.screens.allSatisfy { screen in
            // A picture the owner chose while engaged stays; a saved one that's gone can't come back.
            guard let display = Self.display(screen), let picture = pictures.first(where: { $0.display == display }),
                  NSWorkspace.shared.desktopImageURL(for: screen)?.lastPathComponent.hasPrefix(Self.prefix) == true,
                  FileManager.default.fileExists(atPath: picture.url.path)
            else { return true }
            var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
            if let scaling = picture.scaling {
                options[.imageScaling] = scaling
            }
            if let clipping = picture.clipping {
                options[.allowClipping] = clipping
            }
            if let fill = picture.fill, fill.count == 4 {
                options[.fillColor] = NSColor(srgbRed: fill[0], green: fill[1], blue: fill[2], alpha: fill[3])
            }
            return (try? NSWorkspace.shared.setDesktopImageURL(picture.url, for: screen, options: options)) != nil
        }
    }

    private static func display(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The picture's edge in pixels: big enough that macOS draws it, still a tiny file.
    private static let side = 64

    private static func color(_ rgba: UInt32) -> NSColor {
        NSColor(srgbRed: HUDTheme.channel(rgba, 24), green: HUDTheme.channel(rgba, 16), blue: HUDTheme.channel(rgba, 8), alpha: 1)
    }

    /// A small picture in the theme's void, stretched across the display.
    private static func write(_ color: NSColor, to url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return false }
        for x in 0 ..< side {
            for y in 0 ..< side {
                rep.setColor(color, atX: x, y: y)
            }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return rep.representation(using: .png, properties: [:]).map { (try? $0.write(to: url)) != nil } ?? false
    }
}

/// Runs work one piece after another, in the order it was asked for, each waiting for the last to finish.
@MainActor
final class ShellQueue {
    private var last: Task<Void, Never>?

    func run(_ work: @escaping @MainActor () async -> Void) async {
        let previous = last
        let next = Task { @MainActor in
            await previous?.value
            await work()
        }
        last = next
        await next.value
    }
}
