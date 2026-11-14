import AudioToolbox
import CoreAudio
import IOKit.ps
import Network
import SwiftUI

/// What the right of AegisShell's bar reads: the volume, the network and the battery. Watched only while the bar shows
/// (`start`, `stop`): the default output's volume and mute as they change, the network's path (never its name), and the
/// battery when macOS says a power source changed.
@MainActor @Observable
final class ShellSystemStatus {
    enum Network: Equatable {
        case wifi, wired, other, offline
    }

    struct Battery: Equatable {
        /// Percent, 0–100.
        let level: Int
        /// Filling from the charger.
        let charging: Bool
        /// On the charger, filling or full.
        let plugged: Bool
        /// Minutes until full while charging, or until empty off the charger; nil while macOS is still working it out.
        var minutes: Int?
    }

    struct Volume: Equatable {
        /// Percent, 0–100.
        let level: Int
        let muted: Bool
    }

    var network = Network.offline
    /// Nil on a Mac without a battery.
    var battery: Battery?
    /// Nil when the default output has no volume of its own (some displays and interfaces).
    var volume: Volume?

    @ObservationIgnored private var path: NWPathMonitor?
    @ObservationIgnored private var power: CFRunLoopSource?
    @ObservationIgnored private var audio: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// The one watching, for macOS's power callback, which can't carry a reference.
    private weak static var watching: ShellSystemStatus?

    func start() {
        let path = NWPathMonitor()
        path.pathUpdateHandler = { [weak self] update in
            let network = Self.network(update)
            MainActor.assumeIsolated { self?.network = network }
        }
        path.start(queue: .main)
        self.path = path
        Self.watching = self
        readBattery()
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { ShellSystemStatus.watching?.readBattery() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            power = source
        }
        listenToAudio()
    }

    func stop() {
        path?.cancel()
        path = nil
        if let power {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), power, .commonModes)
        }
        power = nil
        stopListeningToAudio()
    }

    /// The default output's volume and mute, watched on that device and on which device is the default.
    private func listenToAudio() {
        stopListeningToAudio()
        let changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in MainActor.assumeIsolated { self?.readVolume() } }
        let rewire: AudioObjectPropertyListenerBlock = { [weak self] _, _ in MainActor.assumeIsolated { self?.listenToAudio() } }
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, rewire)
        if let device = Self.outputDevice() {
            listen(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput, changed)
            listen(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, changed)
        }
        readVolume()
    }

    private func stopListeningToAudio() {
        for (object, address, block) in audio {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        audio = []
    }

    private func listen(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address), AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr
        else { return }
        audio.append((object, address, block))
    }

    private func readVolume() {
        guard let device = Self.outputDevice(), let level: Float32 = Self.property(
            device,
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        )
        else { return volume = nil }
        let muted: UInt32 = Self.property(device, kAudioDevicePropertyMute) ?? 0
        volume = Volume(level: min(100, max(0, Int((level * 100).rounded()))), muted: muted != 0)
    }

    private static func outputDevice() -> AudioObjectID? {
        let device: AudioObjectID? = property(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal
        )
        return device == AudioObjectID(kAudioObjectUnknown) ? nil : device
    }

    private static func property<Value: BitwiseCopyable>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput
    ) -> Value? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<Value>.size)
        let value = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<Value>.size, alignment: MemoryLayout<Value>.alignment)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.load(as: Value.self)
    }

    private func readBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return battery = nil }
        battery = sources.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .compactMap(Self.battery).first
    }

    /// The Mac's own battery from one power source's description; nil for anything else (a UPS, a mouse).
    nonisolated static func battery(_ description: [String: Any]) -> Battery? {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let full = description[kIOPSMaxCapacityKey] as? Int, full > 0
        else { return nil }
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let plugged = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        // macOS gives -1 while it's still working the time out; a full battery on the charger has no time to give.
        let minutes = charging || !plugged ? (description[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int)
            .flatMap { $0 > 0 ? $0 : nil } : nil
        return Battery(level: min(100, max(0, current * 100 / full)), charging: charging, plugged: plugged, minutes: minutes)
    }

    nonisolated static func network(_ path: NWPath) -> Network {
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.wifi) {
            return .wifi
        }
        return path.usesInterfaceType(.wiredEthernet) ? .wired : .other
    }
}

/// The right of AegisShell's bar, where macOS's own items sat (owner's choice, 2026-11-13; macOS colours those for the
/// wallpaper, so they vanished over the dark bar): the privacy switch, then the volume, the network, the battery and the
/// date and time, in white. The switch turns Hide details on and off; the readings open their System Settings pages
/// through the action safety system; the clock opens the panel.
struct ShellBarReadings: View {
    let shell: ShellController
    let status: ShellSystemStatus
    let close: () -> Void
    @Environment(\.hudTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            Button {
                close()
                shell.hideDetails.toggle()
            } label: {
                ShellIconView(icon: shell.hideDetails ? .hidden : .eye, size: 15).modifier(BarItem())
            }
            .buttonStyle(ShellRowStyle())
            .help(shell.hideDetails ? "Details hidden: click to show names and words" : "Hide details")
            .accessibilityLabel("Hide details")
            .accessibilityValue(shell.hideDetails ? "On" : "Off")
            if let volume = status.volume {
                item(Self.spoken(volume), page: "sound") { ShellIconView(icon: Self.icon(volume), size: 15) }
            }
            let network = Self.words(status.network)
            item(network.spoken, page: status.network == .wifi ? "wifi" : "network") {
                HStack(spacing: 5) {
                    ShellIconView(icon: network.icon, size: 15)
                    if status.network == .offline {
                        Text(network.spoken)
                    }
                }
            }
            if let battery = status.battery {
                item(Self.spoken(battery), page: "battery") { gauge(battery) }
            }
            Button {
                close()
                shell.openPanel()
            } label: {
                TimelineView(.everyMinute) { context in
                    // The day and the time apart, as macOS's own clock shows them (no "at"), in the Mac's own format.
                    let day = context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    Text("\(day)  \(context.date.formatted(.dateTime.hour().minute()))").monospacedDigit()
                }
                .modifier(BarItem())
            }
            .buttonStyle(ShellRowStyle())
            .help("Open the panel")
        }
        .fixedSize()
        .padding(.trailing, 8)
    }

    /// The network's icon and its word, never its name.
    static func words(_ network: ShellSystemStatus.Network) -> (icon: ShellIcon, spoken: String) {
        switch network {
        case .wifi: (.wifi, "Wi-Fi")
        case .wired: (.wired, "Ethernet")
        case .other: (.wired, "Connected")
        case .offline: (.offline, "Offline")
        }
    }

    static func spoken(_ battery: ShellSystemStatus.Battery) -> String {
        let time = battery.minutes.map { String(format: "%d:%02d", $0 / 60, $0 % 60) }
        return "Battery \(battery.level)%" + (battery.charging ? ", charging" : battery.plugged ? ", on power" : "")
            + (time.map { battery.charging ? ", full in \($0)" : ", \($0) left" } ?? "")
    }

    static func spoken(_ volume: ShellSystemStatus.Volume) -> String {
        volume.muted ? "Muted" : "Volume \(volume.level)%"
    }

    /// The speaker with no, one or two waves by level; crossed out when muted.
    static func icon(_ volume: ShellSystemStatus.Volume) -> ShellIcon {
        volume.muted ? .speakerMuted : volume.level == 0 ? .speaker : volume.level < 50 ? .speakerLow : .speakerHigh
    }

    /// The level as a number and a square cell, filled to it; low and off the charger, the fill turns critical (the
    /// number says so too).
    private func gauge(_ battery: ShellSystemStatus.Battery) -> some View {
        let low = battery.level <= 20 && !battery.plugged
        return HStack(spacing: 5) {
            Text("\(battery.level)%").monospacedDigit()
            HStack(spacing: 1) {
                Rectangle().strokeBorder(.white.opacity(0.9), lineWidth: 1)
                    .frame(width: 22, height: 11)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(low ? theme.color(.critical) : .white)
                            .frame(width: max(1, 18 * CGFloat(battery.level) / 100), height: 7)
                            .padding(.leading, 2)
                    }
                Rectangle().fill(.white.opacity(0.9)).frame(width: 2, height: 5)
            }
            if battery.charging {
                ShellIconView(icon: .bolt, size: 12)
            }
        }
    }

    private func item(_ spoken: String, page: String, @ViewBuilder label: () -> some View) -> some View {
        Button {
            close()
            Task { await shell.model?.launch(.automate(.settingsPage, argument: page)) }
        } label: {
            label().modifier(BarItem())
        }
        .buttonStyle(ShellRowStyle())
        .help(spoken)
        .accessibilityLabel(spoken)
        .accessibilityHint("Opens its System Settings page")
    }
}
