import Darwin
import Foundation
import IOKit

/// The Mac's own readings for the SYSTEM and HOME screens: processor, memory, disk, network and graphics load, and
/// Aegis's processes. Sampled twice a second only while one of those screens shows; counts and rates only, kept in
/// memory, never written or logged.
@MainActor @Observable
final class SystemMonitor {
    static let shared = SystemMonitor()
    /// Seconds between samples.
    static let interval = 0.5
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

    struct Process: Sendable {
        let name: String
        let cpu: Double
        let memory: UInt64
        let aegis: Bool
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
        if listing {
            (reading.processes, reading.modelMemory) = processes(seconds: seconds)
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

    // MARK: Processes

    /// Aegis's own processes, then the busiest others to make six, with their processor share and memory.
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
            let name = aegis ? URL(fileURLWithPath: path).lastPathComponent : Self.name(pid)
            if aegis, name == "ModelService" {
                model = usage.ri_phys_footprint
            }
            rows.append(SystemReading.Process(name: name, cpu: cpu, memory: usage.ri_phys_footprint, aegis: aegis))
        }
        processTimes = times
        let own = rows.filter(\.aegis).sorted { $0.memory > $1.memory }
        let others = rows.filter { !$0.aegis }.sorted { $0.cpu > $1.cpu }.prefix(max(0, 6 - own.count))
        return (Array((own + others).prefix(6)), model)
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
