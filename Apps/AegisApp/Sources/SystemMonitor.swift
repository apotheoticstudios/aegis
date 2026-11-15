import Darwin
import Foundation
import IOKit
import IOKit.ps

/// The Mac's own readings for the SYSTEM and HOME screens: processor, memory, disk, network and graphics load, and
/// Aegis's processes. Sampled once a second only while one of those screens shows; counts and rates only, kept in
/// memory, never written or logged.
@MainActor @Observable
final class SystemMonitor {
    static let shared = SystemMonitor()
    /// Seconds between samples.
    static let interval = 1.0
    /// How many samples each history keeps: the last minute.
    static let historyLength = Int(60 / interval)

    private(set) var reading = SystemReading()
    private(set) var cpuHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    private(set) var networkHistory: [Double] = []
    private(set) var diskHistory: [Double] = []
    @ObservationIgnored private var reader = SystemReader()
    @ObservationIgnored private var generation = 0

    /// Samples until the calling task is cancelled (a screen's `.task` ends when it disappears or the panel closes) or
    /// a newer screen takes over. `processes` also reads every process, which only SYSTEM shows.
    func run(processes: Bool) async {
        generation += 1
        let mine = generation
        while !Task.isCancelled, generation == mine {
            let reader = reader
            let (next, sampled) = await Task.detached(priority: .utility) {
                var copy = reader
                let sample = copy.read(processes: processes)
                return (copy, sample)
            }.value
            guard !Task.isCancelled, generation == mine else { return }
            self.reader = next
            reading = sampled
            Self.append(sampled.cpu, to: &cpuHistory)
            Self.append(sampled.gpu ?? 0, to: &gpuHistory)
            Self.append(sampled.networkIn, to: &networkHistory)
            Self.append(sampled.diskBytes, to: &diskHistory)
            try? await Task.sleep(for: .seconds(Self.interval))
        }
    }

    private static func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength {
            history.removeFirst(history.count - historyLength)
        }
    }
}

/// One second of readings. Rates are per second since the previous sample; nil means the Mac didn't say.
struct SystemReading: Sendable {
    struct Core: Sendable {
        /// The core's kind as the Mac names it, its first letter, then its number: E01, S05.
        let label: String
        let load: Double
    }

    /// One app (its helper processes counted with it) or one other process.
    struct Process: Sendable {
        let name: String
        /// Processor time per second: 1 is one core in full use.
        let cpu: Double
        let memory: UInt64
        let aegis: Bool
        /// An app the owner could quit, rather than part of macOS.
        var app = false
    }

    struct Battery: Sendable, Equatable {
        let level: Double
        let charging: Bool
    }

    var cores: [Core] = []
    var cpu = 0.0
    var memoryUsed: UInt64 = 0
    var memoryTotal = ProcessInfo.processInfo.physicalMemory
    var swapUsed: UInt64 = 0
    var diskUsed: UInt64 = 0
    var diskTotal: UInt64 = 0
    var networkIn = 0.0
    var diskBytes = 0.0
    var gpu: Double?
    var thermal = ProcessInfo.ThermalState.nominal
    var load = 0.0
    /// Aegis's own processes first, then the Mac's busiest others.
    var processes: [Process] = []
    /// The local model's memory while ModelService is loaded; nil when it has exited.
    var modelMemory: UInt64?
    /// The other app or process using the most memory.
    var heaviest: Process?
    /// Nil on a Mac without a battery.
    var battery: Battery?
}

/// Reads the counters and keeps the previous ones, to turn totals into rates.
struct SystemReader: Sendable {
    private var ticks: [[UInt64]] = []
    private var networkTotal: UInt64?
    private var diskTotal: UInt64?
    private var processTimes: [Int32: UInt64] = [:]
    private var sampledAt: UInt64?
    private var diskCheckedAt: Date?
    private var disk: (used: UInt64, total: UInt64) = (0, 0)

    mutating func read(processes listing: Bool) -> SystemReading {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let seconds = sampledAt.map { Double(now - $0) / 1e9 } ?? 1
        sampledAt = now
        var reading = SystemReading()
        reading.cores = cores()
        reading.cpu = reading.cores.isEmpty ? 0 : reading.cores.map(\.load).reduce(0, +) / Double(reading.cores.count)
        (reading.memoryUsed, reading.swapUsed) = Self.memory()
        // The volume's free space is slow to ask for; once a minute is plenty.
        if diskCheckedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            disk = Self.disk()
            diskCheckedAt = Date()
        }
        (reading.diskUsed, reading.diskTotal) = disk
        reading.networkIn = Self.rate(Self.networkBytesIn(), previous: &networkTotal, seconds: seconds)
        reading.diskBytes = Self.rate(Self.diskBytesMoved(), previous: &diskTotal, seconds: seconds)
        reading.gpu = Self.gpuUtilisation()
        reading.thermal = ProcessInfo.processInfo.thermalState
        var averages = [0.0, 0.0, 0.0]
        if getloadavg(&averages, 3) > 0 {
            reading.load = averages[0]
        }
        reading.battery = Self.battery()
        if listing {
            let (all, model) = processes(seconds: seconds)
            let own = all.filter(\.aegis).sorted { $0.memory > $1.memory }
            let others = all.filter { !$0.aegis }
            reading.processes = Array((own + others.sorted { $0.cpu > $1.cpu }.prefix(max(0, 6 - own.count))).prefix(6))
            reading.modelMemory = model
            reading.heaviest = others.max { $0.memory < $1.memory }
        }
        return reading
    }

    private static func rate(_ total: UInt64?, previous: inout UInt64?, seconds: Double) -> Double {
        defer { previous = total }
        guard let total, let before = previous, total >= before, seconds > 0 else { return 0 }
        return Double(total - before) / seconds
    }

    // MARK: Processor

    private mutating func cores() -> [SystemReading.Core] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        let states = Int(CPU_STATE_MAX)
        let current = (0 ..< Int(count)).map { core in
            (0 ..< states).map { UInt64(UInt32(bitPattern: info[core * states + $0])) }
        }
        defer { ticks = current }
        let names = Self.coreNames(count: Int(count))
        return current.indices.map { core in
            let before = core < ticks.count ? ticks[core] : Array(repeating: 0, count: states)
            let delta = zip(current[core], before).map { $0 &- $1 }
            let total = delta.reduce(0, +)
            let idle = delta[Int(CPU_STATE_IDLE)]
            return SystemReading.Core(label: names[core], load: total == 0 ? 0 : Double(total - idle) / Double(total))
        }
    }

    // shortcut: assumes the Mac numbers its slowest cores first, as Apple silicon does; read the cluster IDs if a
    // chip ever numbers them otherwise.
    private static func coreNames(count: Int) -> [String] {
        let levels = sysctlInt("hw.nperflevels") ?? 1
        var names: [String] = []
        for level in (0 ..< levels).reversed() {
            let cores = sysctlInt("hw.perflevel\(level).logicalcpu") ?? 0
            let letter = sysctlString("hw.perflevel\(level).name")?.first.map(String.init) ?? "C"
            names += Array(repeating: letter, count: cores)
        }
        return (0 ..< count).map { ($0 < names.count ? names[$0] : "C") + String(format: "%02d", $0 + 1) }
    }

    // MARK: Memory and disk

    /// Used memory as Activity Monitor counts it (app, wired and compressed), and swap in use.
    private static func memory() -> (used: UInt64, swap: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0
                .withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
                }
        }
        let page = UInt64(getpagesize())
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        let pages = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? swap.xsu_used : 0
        return (result == KERN_SUCCESS ? pages * page : 0, swapUsed)
    }

    private static func disk() -> (used: UInt64, total: UInt64) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = UInt64(values?.volumeTotalCapacity ?? 0)
        let free = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
        return (total > free ? total - free : 0, total)
    }

    // MARK: Network, disk activity and graphics

    /// Bytes received by every interface except loopback since start-up. The counters are 32-bit, so a wrap past 4 GB
    /// reads as one quiet second.
    private static func networkBytesIn() -> UInt64? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var total: UInt64 = 0
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let data = interface.ifa_data,
                  String(cString: interface.ifa_name) != "lo0" else { continue }
            total += UInt64(data.assumingMemoryBound(to: if_data.self).pointee.ifi_ibytes)
        }
        return total
    }

    /// Bytes read and written by every disk since start-up, from the storage drivers' statistics.
    private static func diskBytesMoved() -> UInt64? {
        registryValues(class: "IOBlockStorageDriver", property: "Statistics") { statistics in
            ["Bytes (Read)", "Bytes (Write)"].compactMap { (statistics[$0] as? NSNumber)?.uint64Value }.reduce(0, +)
        }.map { $0.reduce(0, +) }
    }

    /// The graphics processor's utilisation, 0 to 1, as its driver reports it.
    private static func gpuUtilisation() -> Double? {
        registryValues(class: "IOAccelerator", property: "PerformanceStatistics") { statistics in
            (statistics["Device Utilization %"] as? NSNumber)?.uint64Value ?? 0
        }.flatMap { $0.max() }.map { Double($0) / 100 }
    }

    private static func registryValues(class name: String, property: String, value: ([String: Any]) -> UInt64) -> [UInt64]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var values: [UInt64] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let found = IORegistryEntryCreateCFProperty(service, property as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            if let properties = found as? [String: Any] {
                values.append(value(properties))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return values.isEmpty ? nil : values
    }

    /// The internal battery's charge and whether it's charging, from the power sources macOS reports.
    private static func battery() -> SystemReading.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let found = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  found[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = found[kIOPSCurrentCapacityKey] as? Int, let maximum = found[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            return .init(level: Double(current) / Double(maximum), charging: found[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }

    // MARK: Processes

    /// Every app (its helpers counted with it) and other process, and Aegis's own processes one by one, with their
    /// processor share and memory; and the model's memory.
    private mutating func processes(seconds: Double) -> ([SystemReading.Process], UInt64?) {
        let bundle = Bundle.main.bundlePath
        var buffer = [pid_t](repeating: 0, count: 4096)
        let found = Int(proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<pid_t>.stride)))
        var times: [Int32: UInt64] = [:]
        var rows: [SystemReading.Process] = []
        var model: UInt64?
        for pid in buffer.prefix(max(0, found)) where pid > 0 {
            var usage = rusage_info_v4()
            let read = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard read == 0 else { continue }
            let time = Self.nanoseconds(usage.ri_user_time + usage.ri_system_time)
            times[pid] = time
            let cpu = processTimes[pid].map { time > $0 ? Double(time - $0) / 1e9 / seconds : 0 } ?? 0
            let path = Self.path(pid)
            let aegis = path.hasPrefix(bundle)
            let app = aegis ? nil : Self.appName(path)
            let name = aegis ? URL(fileURLWithPath: path).lastPathComponent : app ?? Self.name(pid)
            if aegis, name == "ModelService" {
                model = usage.ri_phys_footprint
            }
            rows.append(SystemReading.Process(name: name, cpu: cpu, memory: usage.ri_phys_footprint, aegis: aegis, app: app != nil))
        }
        processTimes = times
        // An app's helpers (a browser's tabs, say) count as the app, as the owner thinks of it.
        let grouped = Dictionary(grouping: rows, by: \.name).values.map { group in
            SystemReading.Process(
                name: group[0].name, cpu: group.map(\.cpu).reduce(0, +), memory: group.map(\.memory).reduce(0, +), aegis: group[0].aegis,
                app: group[0].app
            )
        }
        return (grouped, model)
    }

    /// The app a process belongs to: the outermost .app in its path ("Google Chrome" for its helpers), or nil.
    static func appName(_ path: String) -> String? {
        path.split(separator: "/").first { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
    }

    private static func path(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
    }

    private static func name(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "pid \(pid)"
    }

    /// rusage times are in Mach ticks on Apple silicon.
    private static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return base.denom == 0 ? ticks : ticks * UInt64(base.numer) / UInt64(base.denom)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        return sysctlbyname(name, &buffer, &size, nil, 0) == 0 ? String(cString: buffer) : nil
    }
}

// MARK: - "Why is my Mac slow?"

/// The Performance Monitor's answer (DESIGN.md › Addons): what's straining the Mac right now, the app behind it, and the
/// words to quit it. From one reading on this Mac; nothing leaves it.
extension SystemReading {
    /// Questions about the Mac being slow, hot or loud, or what's using it.
    static func asksWhySlow(_ question: String) -> Bool {
        question.range(
            of: #"\b(?:mac|computer|laptop)\b.*\b(?:slow|sluggish|laggy|lagging|hot|loud|freezing|struggling)\b"#
                + #"|\bwhat'?s (?:slowing|using|eating|hogging)\b|\bwhy is (?:it|everything) (?:so )?(?:slow|laggy)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    var diagnosis: String {
        let gigabyte = 1_073_741_824.0
        let share = Double(memoryUsed) / Double(max(memoryTotal, 1))
        let busiest = processes.filter { !$0.aegis }.max { $0.cpu < $1.cpu }
        let ofProcessor = busiest.map { $0.cpu / Double(max(cores.count, 1)) } ?? 0
        var strains: [String] = []
        var culprit: Process?
        if thermal == .serious || thermal == .critical {
            strains.append("it's running hot, so macOS is slowing it down to cool off")
        }
        if cpu >= 0.6 {
            if let busiest, ofProcessor >= 0.2 {
                strains.append("\(busiest.name) is using \(Self.percent(ofProcessor)) of the processor")
                culprit = busiest
            } else {
                strains.append("the processor is \(Self.percent(cpu)) busy")
            }
        }
        if share >= 0.85 || (Double(swapUsed) >= 2 * gigabyte && share >= 0.7) {
            let heavy = heaviest.flatMap { Double($0.memory) >= gigabyte ? $0 : nil }
            strains
                .append("memory is \(Self.percent(share)) full" + (heavy.map { ", with \($0.name) using \(Self.size($0.memory))" } ?? ""))
            culprit = culprit ?? heavy
        }
        if diskTotal > 0, Double(diskTotal - min(diskUsed, diskTotal)) < Double(diskTotal) * 0.1 {
            strains.append("the disk is nearly full, with \(Self.size(diskTotal - min(diskUsed, diskTotal))) free")
        }
        guard !strains.isEmpty else {
            return "Nothing is straining your Mac right now: the processor is \(Self.percent(cpu)) busy and "
                + "\(Self.size(memoryUsed)) of \(Self.size(memoryTotal)) of memory is in use. If it was slow a moment ago, it has passed."
        }
        let because = strains.count == 1 ? strains[0] : strains.dropLast().joined(separator: ", ") + " and " + strains[strains.count - 1]
        let offer = culprit.flatMap { $0.app ? " Say “quit \($0.name)” to close it; it will ask about anything unsaved." : nil } ?? ""
        return "Your Mac is slow because " + because + "." + offer
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    private static func size(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
