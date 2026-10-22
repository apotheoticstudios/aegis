import AegisKit
import SwiftUI

/// 02 SYSTEM, diagnostics wired to a beating heart: the Mac's processors and memory on the left, the local model,
/// the busiest processes, input and output on the right, and the last minute of processor load below.
/// Everything here is measured on this Mac, once a second, only while this screen shows.
struct SystemScreen: View {
    let model: PanelModel
    @Binding var screen: HUDScreen
    @State private var monitor = SystemMonitor.shared
    @State private var core: CoreStatus?

    var body: some View {
        let reading = monitor.reading
        HUDShell(wires: true) {
            HUDTopBar(model: model, screen: $screen)
        } content: {
            HStack(alignment: .top, spacing: HUD.space6) {
                // The side columns scroll: a Mac with many cores, or a short panel, outgrows them.
                ScrollView { machine(reading) }.scrollIndicators(.never).frame(width: 250)
                heart(reading).frame(maxWidth: .infinity)
                ScrollView { services(reading) }.scrollIndicators(.never).frame(width: 250)
            }
        } bottom: {
            load
        }
        .task(id: HUDPresence.shared.open) {
            guard HUDPresence.shared.open else { return }
            await monitor.run(processes: true)
        }
        .task {
            if case let .status(status) = await model.service.handle(.status) {
                core = status
            }
        }
    }

    // MARK: Processors and memory

    private func machine(_ reading: SystemReading) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDSection(title: "CPU cores", code: "\(reading.cores.count) CORES", first: true) {
                VStack(spacing: 6) {
                    ForEach(reading.cores, id: \.label) { core in
                        HUDMeter(label: core.label, value: core.load, size: .small, tone: core.load > 0.85 ? HUD.warn : HUD.primary)
                    }
                }
            }
            HUDSection(title: "Memory", code: HUDFormat.bytes(Double(reading.memoryTotal)), index: 1) {
                let total = Double(max(reading.memoryTotal, 1))
                let modelMemory = Double(reading.modelMemory ?? 0)
                VStack(spacing: HUD.space3) {
                    HUDMeter(
                        label: "Model" + (model.stored?.brief.model.map { " (\($0))" } ?? ""), value: modelMemory / total,
                        display: reading.modelMemory == nil ? "Idle" : HUDFormat.bytes(modelMemory)
                    )
                    HUDMeter(
                        label: "Apps", value: max(0, Double(reading.memoryUsed) - modelMemory) / total,
                        display: HUDFormat.bytes(max(0, Double(reading.memoryUsed) - modelMemory))
                    )
                    HUDMeter(
                        label: "Swap",
                        value: Double(reading.swapUsed) / total,
                        display: HUDFormat.bytes(Double(reading.swapUsed)),
                        size: .small
                    )
                }
            }
        }
    }

    // MARK: The heart

    private func heart(_ reading: SystemReading) -> some View {
        let coverage = model.stored?.coverage ?? []
        let healthy = coverage.filter { [.ok, .noData].contains($0.status) && !model.health.map(\.source).contains($0.source) }
        let disk = Double(reading.diskUsed) / Double(max(reading.diskTotal, 1))
        return VStack(spacing: 0) {
            HUDAsciiArt(
                shape: .anatomy, cols: 52, rows: 26, grit: 0.12, tone: HUD.critical, label: "A beating heart: the Mac's vitals", hub: true
            )
            HStack(spacing: HUD.space8) {
                HUDReadout(label: "CPU", value: "\(Int((reading.cpu * 100).rounded()))", unit: "%", tone: HUD.critical)
                HUDReadout(label: "Health", value: coverage.isEmpty ? "----" : "\(healthy.count * 100 / coverage.count)", unit: "%")
                HUDReadout(label: "Load", value: String(format: "%.2f", reading.load))
            }
            .padding(.top, HUD.space2)
            .padding(.bottom, HUD.space2)
            HStack(spacing: 0) {
                let thermal = Thermal(reading.thermal)
                HUDRing(value: thermal.value, label: "Thermal", display: thermal.word, tone: thermal.tone)
                Spacer(minLength: 0)
                HUDRing(
                    value: reading.gpu ?? 0, label: "GPU", display: reading.gpu.map { HUDFormat.percent($0) } ?? "----", tone: HUD.accent
                )
                Spacer(minLength: 0)
                HUDRing(value: disk, label: "Disk", display: HUDFormat.percent(disk), tone: disk > 0.8 ? HUD.warn : HUD.primary)
            }
            .frame(maxWidth: 560)
            .scaleEffect(0.72)
            .frame(height: 120)
        }
    }

    // MARK: Model, processes, input and output

    private func services(_ reading: SystemReading) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDSection(title: "Model", code: "LLM.01", first: true) {
                VStack(alignment: .leading, spacing: HUD.space3) {
                    HStack {
                        HUDReadout(
                            label: "Memory", value: reading.modelMemory.map { String(format: "%.1f", Double($0) / 1e9) } ?? "----",
                            unit: "GB",
                            tone: reading.modelMemory == nil ? HUD.ink : HUD.primary
                        )
                        Spacer()
                        HUDReadout(label: "State", value: core?.generating == true ? "Busy" : reading.modelMemory == nil ? "Idle" : "Ready")
                    }
                    HStack {
                        HUDReadout(label: "Last brief", value: Self.time(core?.lastBriefAt ?? model.stored?.storedAt))
                        Spacer()
                        HUDReadout(label: "Next", value: Self.time(core?.nextBriefAt))
                    }
                }
            }
            HUDSection(title: "Processes", code: "TOP \(reading.processes.count)", index: 1) {
                VStack(spacing: 0) {
                    processRow("Name", "CPU", "Mem", header: true)
                    ForEach(Array(reading.processes.enumerated()), id: \.offset) { _, process in
                        processRow(
                            process.name,
                            HUDFormat.percent(process.cpu, capped: false),
                            HUDFormat.bytes(Double(process.memory)),
                            aegis: process.aegis
                        )
                    }
                }
            }
            HUDSection(title: "I/O", code: "NET · DISK", index: 2) {
                VStack(spacing: HUD.space3) {
                    HUDSparkline(
                        label: "Net down", data: Array(monitor.networkHistory.suffix(13)),
                        display: HUDFormat.bytes(reading.networkIn, perSecond: true), height: 40
                    )
                    HUDSparkline(
                        label: "Disk I/O", data: Array(monitor.diskHistory.suffix(14)),
                        display: HUDFormat.bytes(reading.diskBytes, perSecond: true), variant: .bars, height: 40
                    )
                }
            }
        }
    }

    private func processRow(_ name: String, _ cpu: String, _ memory: String, header: Bool = false, aegis: Bool = false) -> some View {
        HStack(spacing: HUD.space2) {
            Text(name).foregroundStyle(header ? HUD.inkMuted : aegis ? HUD.primary : HUD.ink).frame(
                maxWidth: .infinity,
                alignment: .leading
            )
            Text(cpu).foregroundStyle(HUD.inkMuted).frame(width: 52, alignment: .trailing)
            Text(memory).foregroundStyle(HUD.inkMuted).frame(width: 64, alignment: .trailing)
        }
        .modifier(HUDTableType(header: header))
        .lineLimit(1)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { HUDRule() }
    }

    private static func time(_ date: Date?) -> String {
        date.map { $0.formatted(date: .omitted, time: .shortened) } ?? "----"
    }

    // MARK: Load over the last minute

    private var load: some View {
        let cpu = monitor.cpuHistory.map { $0 * 100 }
        let peak = cpu.indices.max { cpu[$0] < cpu[$1] }
        let average = cpu.isEmpty ? 0 : cpu.reduce(0, +) / Double(cpu.count)
        let peakTime = peak.map { Date().addingTimeInterval(-Double(cpu.count - 1 - $0)) }
        return HUDParticleField(
            label: "CPU load · last minute",
            display: "\(Int(average.rounded()))% avg",
            data: cpu,
            spread: zip(cpu, [cpu.first ?? 0] + cpu).map { 0.05 + abs($0 - $1) / 250 },
            trail: monitor.gpuHistory.map { $0 * 100 },
            ticks: ["-60", "", "-50", "", "-40", "", "-30", "", "-20", "", "-10", "", "now"],
            captions: ["CPU (cloud)", "GPU (trail)"] + (peak.map { index in
                ["Peak \(Int(cpu[index].rounded()))% at " + (peakTime?.formatted(date: .omitted, time: .standard) ?? "")]
            } ?? []),
            columns: 13,
            height: 110
        )
    }
}

/// The processes table: header in label caps, rows in mono.
private struct HUDTableType: ViewModifier {
    let header: Bool

    func body(content: Content) -> some View {
        if header {
            content.hudType(.label)
        } else {
            content.hudType(.term)
        }
    }
}

/// macOS reports how hot the Mac runs as a state, not a temperature.
private struct Thermal {
    let value: Double
    let word: String
    let tone: HUDColor

    init(_ state: ProcessInfo.ThermalState) {
        (value, word, tone) = switch state {
        case .nominal: (0.25, "Nom", HUD.primary)
        case .fair: (0.5, "Fair", HUD.primary)
        case .serious: (0.75, "Hot", HUD.warn)
        case .critical: (1, "Crit", HUD.critical)
        @unknown default: (0, "----", HUD.primary)
        }
    }
}
