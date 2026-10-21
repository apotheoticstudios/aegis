// ax-probe: can the Accessibility API see notification banners? (Stage 0, issue #10)
//
// Metadata only: roles, subroles, identifier and text LENGTHS, and whether the owner's own test markers
// appear. Words are read only to be counted or matched; they are never printed or stored. Only the owner
// runs this, in the Terminal app, which needs the Accessibility permission. See README.md.

import AppKit
import ApplicationServices
import AXProbeCore
import Foundation

let notificationCenterBundleID = "com.apple.notificationcenterui"
let usage = """
usage: ax-probe check | tree | watch [--seconds N] [--interval S] [--expect-app TEXT] [--expect-title TEXT] [--expect-body TEXT]
  check   whether Terminal has the Accessibility permission, and whether Notification Center was found
  tree    the structure of Notification Center's windows right now (no text)
  watch   one line per new banner (no text); a summary at the end
  --expect-app/--expect-title/--expect-body  your own test words: the probe reports only whether each was found
"""
let notTrusted = """
Accessibility is not allowed for this Terminal yet.
System Settings > Privacy & Security > Accessibility > turn on Terminal, then quit Terminal (Cmd-Q) and reopen it.
"""

// MARK: - Options

func option(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else {
        return nil
    }
    return args[index + 1]
}

func number(_ name: String, default value: Double) -> Double {
    option(name).flatMap(Double.init) ?? value
}

/// The owner's test markers by label; empty when none were given.
let expected: [String: String] = Dictionary(uniqueKeysWithValues: Markers.labels.compactMap { label in
    option("--expect-\(label)").map { (label, $0) }
})

// MARK: - Reading the live UI (metadata only)

@MainActor
func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

@MainActor
func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    copyAttribute(element, name) as? String
}

@MainActor
func childElements(_ element: AXUIElement, _ name: String = "AXChildren") -> [AXUIElement] {
    (copyAttribute(element, name) as? [AXUIElement]) ?? []
}

/// Length of the element's text and which of the owner's markers it contains, checking every text
/// attribute. The text itself is dropped as soon as it has been counted and matched.
@MainActor
func textInfo(_ element: AXUIElement) -> (length: Int?, matched: [String]) {
    Markers.inspect(["AXValue", "AXTitle", "AXDescription"].map { stringAttribute(element, $0) }, expected: expected)
}

@MainActor
func snapshot(_ element: AXUIElement, depth: Int, budget: inout Int) -> NodeSnapshot {
    budget -= 1
    let text = textInfo(element)
    var node = NodeSnapshot(
        role: stringAttribute(element, "AXRole"),
        subrole: stringAttribute(element, "AXSubrole"),
        identifierLength: stringAttribute(element, "AXIdentifier").map(\.count),
        textLength: text.length,
        matched: text.matched
    )
    guard depth > 0 else {
        return node
    }
    for child in childElements(element) where budget > 0 {
        node.children.append(snapshot(child, depth: depth - 1, budget: &budget))
    }
    return node
}

/// Banner elements under `element`, outermost first.
@MainActor
func bannerElements(under element: AXUIElement, depth: Int = 14) -> [AXUIElement] {
    if let subrole = stringAttribute(element, "AXSubrole"), subrole.hasPrefix(Banners.subrolePrefix) {
        return [element]
    }
    guard depth > 0 else {
        return []
    }
    return childElements(element).flatMap { bannerElements(under: $0, depth: depth - 1) }
}

@MainActor
func notificationCenter() -> (pid: pid_t, element: AXUIElement)? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: notificationCenterBundleID).first else {
        return nil
    }
    return (app.processIdentifier, AXUIElementCreateApplication(app.processIdentifier))
}

@MainActor
func currentBanners(_ app: AXUIElement) -> [AXUIElement] {
    childElements(app, "AXWindows").flatMap { bannerElements(under: $0) }
}

func isTrusted(prompt: Bool) -> Bool {
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
}

func clock() -> String {
    Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
}

// MARK: - Commands

@MainActor
func runCheck() -> Int32 {
    guard isTrusted(prompt: true) else {
        print(notTrusted + "(macOS may have just shown a prompt for this.)")
        return 1
    }
    print("Accessibility: allowed for this Terminal.")
    if notificationCenter() == nil {
        print("Notification Center process: NOT found (\(notificationCenterBundleID)).")
        return 1
    }
    print("Notification Center process: found.")
    return 0
}

@MainActor
func runTree() -> Int32 {
    guard isTrusted(prompt: false) else {
        print(notTrusted)
        return 1
    }
    guard let center = notificationCenter() else {
        print("Notification Center process not found (\(notificationCenterBundleID)).")
        return 1
    }
    let windows = childElements(center.element, "AXWindows")
    print("Notification Center windows: \(windows.count) (structure and lengths only, never text)")
    var budget = 3000
    var banners = 0
    for (index, window) in windows.enumerated() {
        let tree = snapshot(window, depth: 14, budget: &budget)
        banners += Banners.find(in: tree).count
        print("\nWindow \(index + 1):")
        Banners.describe(tree).forEach { print($0) }
    }
    print("\nBanners found: \(banners)")
    if budget <= 0 {
        print("(Stopped early: more than 3000 elements.)")
    }
    return 0
}

/// Shared with the C callback and the Ctrl-C handler; everything runs on the main run loop.
final class Observation: @unchecked Sendable {
    var events: [String: Int] = [:]
    var stop = false
}

/// Subscribes to Accessibility notifications and says which subscriptions worked, so "no events"
/// is only concluded when at least one subscription succeeded.
@MainActor
func subscribe(_ center: (pid: pid_t, element: AXUIElement), _ observation: Observation) -> (observer: AXObserver?, report: String) {
    let callback: AXObserverCallback = { _, _, name, refcon in
        guard let refcon else {
            return
        }
        Unmanaged<Observation>.fromOpaque(refcon).takeUnretainedValue().events[name as String, default: 0] += 1
    }
    var observer: AXObserver?
    let created = AXObserverCreate(center.pid, callback, &observer)
    guard created == .success, let observer else {
        return (nil, "could not create an observer (AXError \(created.rawValue))")
    }
    let refcon = Unmanaged.passUnretained(observation).toOpaque()
    var subscribed: [String] = []
    var failed: [String] = []
    for name in ["AXWindowCreated", "AXCreated", "AXLayoutChanged", "AXUIElementDestroyed"] {
        let status = AXObserverAddNotification(observer, center.element, name as CFString, refcon)
        if status == .success {
            subscribed.append(name)
        } else {
            failed.append("\(name) (AXError \(status.rawValue))")
        }
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    // Element-level events (created, layout changed, destroyed) may be posted on windows rather than
    // on the application, so each window is observed as well; windows that appear later are added
    // by `observeNewWindows`.
    let windows = observeNewWindows(observer, center.element, refcon, already: [])
    if windows.worked > 0 {
        subscribed.append("\(windows.worked) window subscription(s)")
    }
    if windows.failed > 0 {
        failed.append("\(windows.failed) window subscription(s)")
    }
    var report = "subscribed to " + (subscribed.isEmpty ? "nothing" : subscribed.joined(separator: ", "))
    if !failed.isEmpty {
        report += "; failed: " + failed.joined(separator: ", ")
    }
    return (subscribed.isEmpty ? nil : observer, report)
}

/// Subscribes each Notification Center window not yet observed to element-level events, and returns
/// how many individual window subscriptions worked and failed. `already` holds windows observed so far.
@MainActor
@discardableResult
func observeNewWindows(
    _ observer: AXObserver,
    _ app: AXUIElement,
    _ refcon: UnsafeMutableRawPointer,
    already: [AXUIElement]
) -> (worked: Int, failed: Int) {
    var worked = 0
    var failed = 0
    for window in childElements(app, "AXWindows") where !already.contains(where: { CFEqual($0, window) }) {
        for name in ["AXCreated", "AXLayoutChanged", "AXUIElementDestroyed"] {
            if AXObserverAddNotification(observer, window, name as CFString, refcon) == .success {
                worked += 1
            } else {
                failed += 1
            }
        }
    }
    return (worked, failed)
}

@MainActor
func bannerLine(_ summary: BannerSummary) -> String {
    let kind = (summary.subrole ?? "?").padding(toLength: 28, withPad: " ", startingAt: 0)
    if !expected.isEmpty {
        let fields = expected.keys.sorted().map { "\($0): \(summary.found.contains($0) ? "yes" : "no")" }
        return "\(clock())  \(kind)  " + fields.joined(separator: "  ")
    }
    let fields = summary.textLengths.isEmpty
        ? "none"
        : "\(summary.textLengths.count) (" + summary.textLengths.map(String.init).joined(separator: ", ") + ")"
    return "\(clock())  \(kind)  \(fields.padding(toLength: 26, withPad: " ", startingAt: 0))  \(summary.buttons)"
}

@MainActor
func runWatch(seconds: Double, interval: Double) -> Int32 {
    guard isTrusted(prompt: false) else {
        print(notTrusted)
        return 1
    }
    guard let center = notificationCenter() else {
        print("Notification Center process not found (\(notificationCenterBundleID)).")
        return 1
    }
    let observation = Observation()
    let subscription = subscribe(center, observation)

    // Ctrl-C ends the watch and prints the summary.
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler { observation.stop = true }
    interrupt.resume()

    print("Watching Notification Center for up to \(Int(seconds)) s (metadata only). Press Ctrl-C to stop.")
    print("Accessibility events: \(subscription.report)")
    if expected.isEmpty {
        print("Tip: pass --expect-app/--expect-title/--expect-body with your own test words to see which fields are readable.\n")
        print("time      kind                          text fields (lengths)       buttons")
    } else {
        print("Looking for your test words: " + expected.keys.sorted().joined(separator: ", ") + " (only yes/no is shown).\n")
        print("time      kind                          found")
    }
    var observedWindows = childElements(center.element, "AXWindows")
    var showing = currentBanners(center.element) // banners already on screen don't count as new
    var seen: [BannerSummary] = []
    let end = Date.now.addingTimeInterval(seconds)
    while !observation.stop, Date.now < end {
        RunLoop.current.run(until: Date.now.addingTimeInterval(interval))
        if let observer = subscription.observer {
            let refcon = Unmanaged.passUnretained(observation).toOpaque()
            observeNewWindows(observer, center.element, refcon, already: observedWindows)
            observedWindows = childElements(center.element, "AXWindows")
        }
        let current = currentBanners(center.element)
        for element in current where !showing.contains(where: { CFEqual($0, element) }) {
            var budget = 200
            let summary = Banners.summarize(snapshot(element, depth: 8, budget: &budget))
            seen.append(summary)
            print(bannerLine(summary))
        }
        showing = current
    }
    interrupt.cancel()

    print("\nSeen \(seen.count) new banners; \(seen.filter(\.hasText).count) exposed text to Accessibility.")
    for label in expected.keys.sorted() {
        print("Your \(label) words found in \(seen.filter { $0.found.contains(label) }.count) of \(seen.count) banners.")
    }
    if subscription.observer == nil {
        print("Accessibility events: no subscription worked (\(subscription.report)), so this run can't say whether events fire.")
    } else if observation.events.isEmpty {
        print(
            seen.isEmpty
                ? "Accessibility events received: none, although subscribed; polling saw no banners either."
                : "Accessibility events received: none, although subscribed (only polling saw banners)."
        )
    } else {
        let events = observation.events.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }
        print("Accessibility events received: " + events.joined(separator: ", "))
    }
    print("\nFor issue #10, record: banners seen vs notifications shown, which fields were found, and the conditions you tested.")
    print("Never paste notification text anywhere; this tool doesn't show any.")
    return 0
}

// MARK: - Main

let command = CommandLine.arguments.dropFirst().first
let status: Int32 = switch command {
case "check":
    runCheck()
case "tree":
    runTree()
case "watch":
    runWatch(seconds: number("--seconds", default: 600), interval: number("--interval", default: 0.5))
default:
    {
        print(usage)
        return command == nil || command == "--help" || command == "-h" ? 0 : 2
    }()
}
exit(status)
