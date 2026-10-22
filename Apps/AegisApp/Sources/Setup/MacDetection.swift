import AegisKit
import Foundation
import FoundationModels
import IOKit
import IOKit.ps

/// What the setup wizard detects about this Mac (#26), from public system APIs: the kind of Mac, never its name.
extension MacProfile {
    static func detect() -> MacProfile {
        let volume = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return MacProfile(
            model: productName() ?? sysctlString("hw.model") ?? "Mac",
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple silicon",
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            diskTotalBytes: UInt64(max(0, volume?.volumeTotalCapacity ?? 0)),
            diskFreeBytes: UInt64(max(0, volume?.volumeAvailableCapacityForImportantUsage ?? 0)),
            systemVersion: [version.majorVersion, version.minorVersion, version.patchVersion]
                .map(String.init).joined(separator: ".").replacingOccurrences(of: #"\.0$"#, with: "", options: .regularExpression),
            appleIntelligence: appleIntelligenceOn(),
            isLaptop: hasInternalBattery()
        )
    }

    /// "MacBook Air (13-inch, M4, 2025)", from the device tree on Apple silicon.
    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data
        else { return nil }
        return String(bytes: data.prefix { $0 != 0 }, encoding: .utf8)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
    }

    private static func hasInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    /// Apple's on-device model is ready: Apple Intelligence is on and its model downloaded (macOS 26 and later).
    private static func appleIntelligenceOn() -> Bool {
        guard #available(macOS 26, *) else { return false }
        return SystemLanguageModel.default.isAvailable
    }
}
