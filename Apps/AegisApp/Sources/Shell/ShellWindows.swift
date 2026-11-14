import AegisKit
import AppKit
import ApplicationServices

/// AegisShell's window layouts (the design system's ShellWindows, stage 6): "Mail left, calendar right" shows the zones
/// (ShellLayoutZones), then glides each app's front window into its zone with the Accessibility API, after the owner
/// grants Accessibility. Each window's
/// first frame is kept, and every window AegisShell moved goes back on disengage. Each move is logged through the
/// action safety system like any command.
@MainActor
enum ShellWindows {
    /// One window's move in a layout, allowed by the safety system and on its way.
    private struct Move {
        let window: AXUIElement
        let from: CGRect
        let to: CGRect
        let name: String
        let request: ActionRequest
    }

    /// The zones showing for a layout under way, taken down at once on disengage.
    private static var zones: ShellLayoutZones?

    /// The frames windows had before AegisShell first moved them, and whether they were minimised, to put back on disengage.
    private static var original: [(window: AXUIElement, frame: CGRect, minimised: Bool)] = []

    /// What Aegis says, or nil when the words aren't a layout of apps on this Mac (so "turn left" stays a question).
    static func apply(_ placements: [WindowPlacement], model: PanelModel) async -> String? {
        // The engage this layout belongs to: checked again after every wait, so once AegisShell has put windows back (or
        // engaged again since), nothing from this layout opens, moves or comes forward.
        let session = ShellController.shared.session
        let live = { ShellController.shared.current(session) }
        let apps = placements.map { (placement: $0, app: running($0.app), installed: PanelModel.application(named: $0.app)) }
        guard apps.allSatisfy({ $0.app != nil || $0.installed != nil }) else { return nil }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            return "To arrange windows, allow Aegis in System Settings › Privacy & Security › Accessibility, then ask again."
        }
        guard let screen = NSScreen.main, let primary = NSScreen.screens.first else { return nil }
        // Accessibility measures from the top left of the main display; AppKit from the bottom left.
        let visible = screen.visibleFrame
        let area = WindowArea(x: visible.minX, y: primary.frame.maxY - visible.maxY, width: visible.width, height: visible.height)
        var moves: [Move] = []
        for (placement, app, installed) in apps {
            var target = app
            guard live() else { break }
            if target == nil, let installed {
                await model.launch(.openApp(name: installed.deletingPathExtension().lastPathComponent))
                target = await waitForLaunch(installed)
            }
            guard live(), let target, let window = await frontWindow(of: target), live() else { continue }
            let request = ActionRequest(payload: .app(bundleID: target.bundleIdentifier ?? placement.app, verb: .move), origin: .ownerTyped)
            guard await model.log(request, .proposed).allowed, live() else { continue }
            let minimised = isMinimised(window)
            remember(window, minimised: minimised)
            // A minimised window comes back only once the move is allowed, and goes back down on disengage.
            if minimised {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            let zone = placement.zone.frame(in: area)
            let to = CGRect(x: zone.x, y: zone.y, width: zone.width, height: zone.height)
            moves.append(Move(
                window: window,
                from: frame(of: window) ?? to,
                to: to,
                name: target.localizedName ?? placement.app,
                request: request
            ))
        }
        // The zones first, then the windows glide into them together (no glide under Reduce Motion), then the zones fade.
        var moved: [String] = []
        if !moves.isEmpty, live() {
            // Kept where disengaging can take it down at once, whatever the moves below are waiting on.
            zones = ShellLayoutZones(moves.map { ($0.name, $0.from, $0.to) }, screen: screen, primary: primary)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                try? await Task.sleep(for: .milliseconds(200))
                await glide(moves, live: live)
            }
            for move in moves {
                // Disengaged meanwhile: AegisShell puts the window back; the log says the move didn't finish.
                guard live() else {
                    await model.log(move.request, .cancelled)
                    continue
                }
                let worked = set(move.window, move.to)
                await model.log(move.request, worked ? .succeeded : .failed)
                if worked {
                    moved.append(move.name)
                }
            }
            zones?.fade()
            zones = nil
        }
        // The first app comes forward only when something moved, and AegisShell is still on.
        if !moved.isEmpty, live(), let first = apps.first?.app ?? apps.first.flatMap({ running($0.placement.app) }) {
            first.activate()
        }
        return moved.isEmpty ? "I couldn't move those windows." : "Done: " + moved.joined(separator: ", ") + "."
    }

    /// On disengage: every window AegisShell moved goes back where it was.
    static func restore() {
        zones?.close()
        zones = nil
        for (window, frame, minimised) in original.reversed() {
            _ = set(window, frame)
            if minimised {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
        }
        original = []
    }

    /// The windows glide together: 300 ms on the design's standard curve, by the clock, so slow apps don't stretch it;
    /// each lands exactly afterwards.
    private static func glide(_ moves: [Move], live: () -> Bool) async {
        let start = Date()
        var gliding = moves
        // A slow app answers within a quarter of a second or is left to land at the end, so it can't hold up the others
        // (or Exit) for long.
        gliding.forEach { AXUIElementSetMessagingTimeout($0.window, 0.25) }
        while live(), !gliding.isEmpty {
            let progress = Date().timeIntervalSince(start) / 0.3
            gliding = gliding.filter { move in
                progress < 1 && live() && place(move.window, ShellLayoutZones.step(from: move.from, to: move.to, progress: progress))
            }
            if progress >= 1 {
                return
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// One glide step: where, then how big; false when the window wouldn't move, so it stops gliding.
    private static func place(_ window: AXUIElement, _ frame: CGRect) -> Bool {
        var point = frame.origin, extent = frame.size
        guard let position = AXValueCreate(.cgPoint, &point), let size = AXValueCreate(.cgSize, &extent),
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success
        else { return false }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size)
        return true
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

    /// The app's main window, waiting a moment for one that's just opening.
    private static func frontWindow(of app: NSRunningApplication) async -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for _ in 0 ..< 15 {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &value) == .success
                || AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
                let value, CFGetTypeID(value) == AXUIElementGetTypeID()
            {
                return value as! AXUIElement // swiftlint:disable:this force_cast
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private static func remember(_ window: AXUIElement, minimised: Bool) {
        guard !original.contains(where: { CFEqual($0.window, window) }), let frame = frame(of: window) else { return }
        original.append((window, frame, minimised))
    }

    private static func isMinimised(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success
            && (value as? Bool) == true
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
