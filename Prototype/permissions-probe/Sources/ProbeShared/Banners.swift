import AppKit
import ApplicationServices
import Foundation

/// Stage 2 probe 0.1 (docs/stages/STAGE-2.md): can this process observe notification banners through the
/// Accessibility API, and which observer notifications fire? Counts and element roles only: it never reads
/// a title, value or description, so no notification text is seen, kept or written.
public struct BannerReport: Codable, Equatable {
    /// `AXIsProcessTrusted()` for this process (never prompts).
    public var trusted: Bool
    /// "running" or "not running" (Notification Center's UI process).
    public var target: String
    /// Observer notification → "ok" or the AXError code from `AXObserverAddNotification`.
    public var registrations: [String: String]
    /// Observer notification → callbacks received (cumulative in the agent).
    public var events: [String: Int]
    /// Role/subrole outlines of the first created elements, depth-limited (structure only, no text).
    public var shapes: [String]
    public var secondsWatched: Double
}

public enum Banners {
    public static let notificationCenter = "com.apple.notificationcenterui"
    static let names = [
        kAXWindowCreatedNotification, kAXCreatedNotification, kAXUIElementDestroyedNotification,
        kAXLayoutChangedNotification, kAXFocusedWindowChangedNotification,
    ]

    final class Tally {
        var events: [String: Int] = [:]
        var shapes: [String] = []
    }

    /// Watches for `seconds` on the current thread's run loop.
    public static func watch(seconds: Double) -> BannerReport {
        var report = BannerReport(
            trusted: AXIsProcessTrusted(), target: "not running", registrations: [:], events: [:], shapes: [],
            secondsWatched: 0
        )
        guard report.trusted else { return report }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: notificationCenter).first else {
            return report
        }
        report.target = "running"
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let tally = Unmanaged<Tally>.fromOpaque(refcon).takeUnretainedValue()
            tally.events[notification as String, default: 0] += 1
            if tally.shapes.count < 3, (notification as String) != kAXUIElementDestroyedNotification {
                tally.shapes.append((notification as String) + ": " + Banners.outline(element, depth: 0))
            }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &created) == .success, let observer = created else {
            report.registrations["create"] = "failed"
            return report
        }
        let tally = Tally()
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for name in names {
            let code = AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(tally).toOpaque())
            report.registrations[name] = code == .success ? "ok" : "error \(code.rawValue)"
        }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        let start = Date()
        CFRunLoopRunInMode(.defaultMode, seconds, false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
        report.secondsWatched = Date().timeIntervalSince(start)
        report.events = tally.events
        report.shapes = tally.shapes
        return report
    }

    /// Role and subrole of an element and its children, at most 4 levels and 40 nodes. No text attributes.
    static func outline(_ element: AXUIElement, depth: Int) -> String {
        var budget = 40
        func walk(_ element: AXUIElement, _ depth: Int) -> String {
            budget -= 1
            let role = attribute(element, kAXRoleAttribute) ?? "?"
            let subrole = attribute(element, kAXSubroleAttribute).map { "/" + $0 } ?? ""
            guard depth < 4, budget > 0 else { return role + subrole }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
                  let children = value as? [AXUIElement], !children.isEmpty
            else { return role + subrole }
            let inner = children.prefix(8).map { walk($0, depth + 1) }.joined(separator: ", ")
            return role + subrole + "[" + inner + "]"
        }
        return walk(element, depth)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Adds a new watch to earlier totals (the agent runs every 15 s).
    public static func accumulate(_ new: BannerReport, onto old: BannerReport?) -> BannerReport {
        guard let old else { return new }
        var merged = new
        merged.events = old.events.merging(new.events, uniquingKeysWith: +)
        merged.shapes = Array((old.shapes + new.shapes).prefix(3))
        merged.secondsWatched = old.secondsWatched + new.secondsWatched
        return merged
    }
}
