import AegisKit
import AppKit
import ApplicationServices

/// AegisShell's window layouts (the design system's ShellWindows, stage 6): "Mail left, calendar right" moves each
/// app's front window into its zone with the Accessibility API, after the owner grants Accessibility. Each window's
/// first frame is kept, and every window AegisShell moved goes back on disengage. Each move is logged through the
/// action safety system like any command.
@MainActor
enum ShellWindows {
    /// The frames windows had before AegisShell first moved them, to put back on disengage.
    private static var original: [(window: AXUIElement, frame: CGRect)] = []

    /// What Aegis says, or nil when the words aren't a layout of apps on this Mac (so "turn left" stays a question).
    static func apply(_ placements: [WindowPlacement], model: PanelModel) async -> String? {
        let apps = placements.map { (placement: $0, app: running($0.app), installed: PanelModel.application(named: $0.app)) }
        guard apps.allSatisfy({ $0.app != nil || $0.installed != nil }) else { return nil }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            return "To arrange windows, allow Aegis in System Settings › Privacy & Security › Accessibility, then ask again."
        }
        guard let screen = NSScreen.main, let primary = NSScreen.screens.first else { return nil }
        // Accessibility measures from the top left of the main display; AppKit from the bottom left.
        let visible = screen.visibleFrame
        let area = WindowArea(x: visible.minX, y: primary.frame.maxY - visible.maxY, width: visible.width, height: visible.height)
        var moved: [String] = []
        for (placement, app, installed) in apps {
            var target = app
            if target == nil, let installed {
                await model.launch(.openApp(name: installed.deletingPathExtension().lastPathComponent))
                target = await waitForLaunch(installed)
            }
            guard let target, let window = await frontWindow(of: target) else { continue }
            let request = ActionRequest(payload: .app(bundleID: target.bundleIdentifier ?? placement.app, verb: .move), origin: .ownerTyped)
            guard await model.log(request, .proposed).allowed else { continue }
            remember(window)
            let frame = placement.zone.frame(in: area)
            let worked = set(window, CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
            await model.log(request, worked ? .succeeded : .failed)
            if worked {
                moved.append(target.localizedName ?? placement.app)
            }
        }
        if let first = apps.first?.app ?? apps.first.flatMap({ running($0.placement.app) }) {
            first.activate()
        }
        return moved.isEmpty ? "I couldn't move those windows." : "Done: " + moved.joined(separator: ", ") + "."
    }

    /// On disengage: every window AegisShell moved goes back where it was.
    static func restore() {
        for (window, frame) in original.reversed() {
            _ = set(window, frame)
        }
        original = []
    }

    /// A running app by the owner's name for it: exact, then one whose name starts with it.
    static func running(_ name: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let wanted = name.lowercased()
        return apps.first { $0.localizedName?.lowercased() == wanted }
            ?? apps.first { wanted.count >= 3 && $0.localizedName?.lowercased().hasPrefix(wanted) == true }
    }

    private static func waitForLaunch(_ url: URL) async -> NSRunningApplication? {
        for _ in 0 ..< 20 {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == url }) {
                return app
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    /// The app's main window, waiting a moment for one that's just opening; a minimised one comes back first.
    private static func frontWindow(of app: NSRunningApplication) async -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for _ in 0 ..< 15 {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &value) == .success
                || AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
                let value, CFGetTypeID(value) == AXUIElementGetTypeID()
            {
                let window = value as! AXUIElement // swiftlint:disable:this force_cast
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                return window
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private static func remember(_ window: AXUIElement) {
        guard !original.contains(where: { CFEqual($0.window, window) }), let frame = frame(of: window) else { return }
        original.append((window, frame))
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size
        else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        // swiftlint:disable force_cast
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        // swiftlint:enable force_cast
        return CGRect(origin: point, size: extent)
    }

    /// Moves, then sizes, then moves again: an app that can't shrink enough may have shifted the first move.
    private static func set(_ window: AXUIElement, _ frame: CGRect) -> Bool {
        var point = frame.origin, extent = frame.size
        guard let position = AXValueCreate(.cgPoint, &point), let size = AXValueCreate(.cgSize, &extent) else { return false }
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success
        let sized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size) == .success
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        return moved || sized
    }
}
