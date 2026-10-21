import AegisKit
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Follows system sleep and wake (step 2.13) through IOKit, which works in a background agent: before sleep
/// the engine cancels a running job (the last brief stays); after wake it catches up the day's brief once.
/// Also follows heat and Low Power Mode, so new generation waits while either holds.
final class PowerMonitor: @unchecked Sendable {
    // IOKit's iokit_common_msg values (C macros Swift doesn't import).
    private static let canSystemSleep: natural_t = 0xE000_0270
    private static let systemWillSleep: natural_t = 0xE000_0280
    private static let systemHasPoweredOn: natural_t = 0xE000_0300

    private let engine: CoreEngine
    private let queue = DispatchQueue(label: "dev.aegis.power")
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var root: io_connect_t = 0

    init(engine: CoreEngine) {
        self.engine = engine
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        root = IORegisterForSystemPower(context, &port, { context, _, message, argument in
            guard let context else {
                return
            }
            Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().handle(message, argument)
        }, &notifier)
        if root != 0, let port {
            IONotificationPortSetDispatchQueue(port, queue)
        }
        let center = NotificationCenter.default
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.conditionsChanged()
        }
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.conditionsChanged()
        }
        conditionsChanged()
    }

    private func handle(_ message: natural_t, _ argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        switch message {
        case Self.canSystemSleep:
            IOAllowPowerChange(root, token)
        case Self.systemWillSleep:
            // Cancel a running job, then let the Mac sleep; never hold sleep back more than 5 seconds.
            let once = AllowOnce(root: root, token: token)
            let engine = engine
            Task {
                await engine.sleep()
                once.allow()
            }
            queue.asyncAfter(deadline: .now() + 5) { once.allow() }
        case Self.systemHasPoweredOn:
            let engine = engine
            Task { await engine.wake() }
        default:
            break
        }
    }

    private func conditionsChanged() {
        let info = ProcessInfo.processInfo
        let hot = info.thermalState == .serious || info.thermalState == .critical
        let low = info.isLowPowerModeEnabled
        let engine = engine
        Task { await engine.conditions(thermalSerious: hot, lowPower: low) }
    }
}

/// Acknowledges a sleep notice exactly once.
private final class AllowOnce: @unchecked Sendable {
    private let lock = NSLock()
    private let root: io_connect_t
    private let token: Int
    private var done = false

    init(root: io_connect_t, token: Int) {
        self.root = root
        self.token = token
    }

    func allow() {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first {
            IOAllowPowerChange(root, token)
        }
    }
}
