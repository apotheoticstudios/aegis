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

/// The other: each display's wallpaper. macOS colours the see-through menu bar's items for the wallpaper, not for the
/// windows behind them, so a dark one while engaged keeps them light and the whole bar dark over AegisShell's desktop.
@MainActor
protocol ShellWallpaper {
    /// Each display's picture; nil when one can't be read.
    func current() -> [ShellSettings.Wallpaper]?
    /// Puts AegisShell's dark picture on every display; whether that worked.
    func darken() -> Bool
    /// Puts the saved pictures back wherever AegisShell's still shows; whether that worked.
    func restore(_ pictures: [ShellSettings.Wallpaper]) -> Bool
}

/// What AegisShell changes is saved before it changes it and put back on disengage, on quit, and on the next launch
/// after a crash (ADR-0033). The saved file is written before anything changes and removed only once the restore
/// worked, so a failure is retried at the next launch.
@MainActor
final class ShellSettings {
    struct Saved: Codable, Equatable {
        var dockAutohide: Bool
        /// Missing in files saved before AegisShell changed the wallpaper, and when it couldn't be read.
        var wallpapers: [Wallpaper]?
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

    /// Saves the Dock's setting and the wallpaper, then hides the Dock and darkens the wallpaper. Whether the Dock is hidden.
    func apply() async -> Bool {
        // Engaged again before a restore went through: the first saving is the owner's own setting.
        if saved == nil {
            guard let current = dock.autohide(),
                  let data = try? JSONEncoder().encode(Saved(dockAutohide: current, wallpapers: wallpaper?.current()))
            else { return false }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                return false
            }
        }
        // Only over a saved picture, so it can always go back. If it fails, the menu bar's strip still shows the wallpaper.
        if saved?.wallpapers != nil {
            _ = wallpaper?.darken()
        }
        return dock.autohide() == true ? true : await dock.set(autohide: true)
    }

    /// Puts back what was saved. Whether macOS is as it was.
    @discardableResult
    func restore() async -> Bool {
        guard let saved else { return true }
        if let pictures = saved.wallpapers, wallpaper?.restore(pictures) == false {
            return false
        }
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
        if let pictures = saved.wallpapers, wallpaper?.restore(pictures) == false {
            return false
        }
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

/// The real wallpaper, through NSWorkspace.
struct SystemWallpaper: ShellWallpaper {
    /// Where AegisShell's dark picture is kept: one per theme, so macOS never shows a stale colour.
    let folder: URL
    private static let prefix = "shell-wallpaper-"

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
        // shortcut: the current Space on each display; a Space first shown while engaged keeps AegisShell's picture until
        // it is engaged and left there again. Upgrade if owners keep different wallpapers per Space.
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
