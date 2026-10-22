import AegisKit
import AppKit
import SwiftUI

/// 01 HOME, the overview: the machine on the left, the world on the right, Aegis at the centre with what matters now,
/// and the last day of activity along the bottom.
struct HomeScreen: View {
    let model: PanelModel
    @Binding var screen: HUDScreen
    @State private var monitor = SystemMonitor.shared
    @State private var activity = ActivityPresence.shared
    /// Today's whole schedule, not just its first rows.
    @State private var wholeDay = false

    var body: some View {
        HUDShell {
            HUDTopBar(model: model, screen: $screen)
        } content: {
            HStack(alignment: .top, spacing: HUD.space8) {
                machine.frame(width: 250)
                centre.frame(maxWidth: .infinity)
                ScrollView { world }.scrollIndicators(.never).frame(width: 250)
            }
        } bottom: {
            HUDParticleField(
                label: "Activity · last 24 h",
                display: "\(Int(activity.total.reduce(0, +))) events",
                data: activity.total,
                spread: activity.total.map { 0.05 + 0.06 * (1 - $0 / max(activity.total.max() ?? 1, 1)) },
                trail: activity.hours([.email]),
                columns: 24,
                height: 130
            )
        }
        .task(id: HUDPresence.shared.open) {
            guard HUDPresence.shared.open else { return }
            await model.refreshActivity()
            await monitor.run(processes: false)
        }
    }

    // MARK: The machine

    private var machine: some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDSection(title: "Systems", code: "SYS.01", first: true) {
                VStack(spacing: HUD.space3) {
                    HUDMeter(label: "CPU", value: monitor.reading.cpu)
                    HUDMeter(
                        label: "Memory", value: Double(monitor.reading.memoryUsed) / Double(max(monitor.reading.memoryTotal, 1)),
                        display: HUDFormat.bytes(Double(monitor.reading.memoryUsed))
                    )
                    let disk = Double(monitor.reading.diskUsed) / Double(max(monitor.reading.diskTotal, 1))
                    HUDMeter(label: "Disk", value: disk, tone: disk > 0.8 ? HUD.warn : HUD.primary)
                }
            }
            HUDSection(title: "Network", code: "NET.03") {
                HUDSparkline(
                    label: "Down", data: Array(monitor.networkHistory.suffix(20)),
                    display: HUDFormat.bytes(monitor.reading.networkIn, perSecond: true), variant: .particles
                )
            }
            HUDSection(title: "Scan", code: "COL.02") {
                HUDAsciiArt(shape: .radar, cols: 34, rows: 12, seed: 5, tone: HUD.primary, label: "Aegis's collectors scanning")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: The centre

    private var centre: some View {
        VStack(spacing: HUD.space4) {
            HUDCore(model: model, value: "\(model.needsYou)")
            Text(model.saying)
                .foregroundStyle(HUD.inkMuted)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: 340)
                .textSelection(.enabled)
            HStack(spacing: HUD.space3) {
                if model.stored != nil {
                    Button(model.voice.speaking ? "Stop" : "Read brief") { model.readBrief() }
                        .buttonStyle(HUDPlateStyle(kind: .primary))
                        .help("Aegis reads the brief aloud")
                }
                Button("World") { WorldWindow.shared.show() }
                    .buttonStyle(HUDPlateStyle())
                    .help("The live globe inside Aegis; steer it by talking to Aegis")
            }
            routine
        }
        .padding(.top, HUD.space4)
    }

    /// The morning routine (#286): each proposal with Yes and No, and Always for jobs Aegis may remember.
    @ViewBuilder private var routine: some View {
        let today = RoutinePresence.shared.today
        let pending = today?.pending ?? []
        let automatic = today?.proposals.filter { $0.remembered && $0.status == .executed } ?? []
        if !pending.isEmpty || !automatic.isEmpty {
            VStack(alignment: .leading, spacing: HUD.space2) {
                HUDHeading(title: "Morning routine", tone: HUD.primary)
                ForEach(pending) { proposal in
                    HStack(alignment: .firstTextBaseline, spacing: HUD.space2) {
                        Text("\(proposal.number)").hudType(.data).foregroundStyle(HUD.inkMuted)
                        Text(proposal.text).lineLimit(2)
                        Spacer(minLength: HUD.space2)
                        Button("Yes") { Task { await model.decideRoutine([proposal], approved: true, always: false) } }
                            .buttonStyle(HUDChipStyle())
                        Button("No") { Task { await model.decideRoutine([proposal], approved: false, always: false) } }
                            .buttonStyle(HUDChipStyle(muted: true))
                        if proposal.tier.canRemember {
                            Menu("Always") {
                                Button("Always yes") { Task { await model.decideRoutine([proposal], approved: true, always: true) } }
                                Button("Always no") { Task { await model.decideRoutine([proposal], approved: false, always: true) } }
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .hudType(.label).foregroundStyle(HUD.inkMuted)
                        }
                    }
                }
                ForEach(automatic) { proposal in
                    Text("✓ " + proposal.text + " (you said always)").hudType(.caption).foregroundStyle(HUD.inkMuted)
                }
            }
            .hudPanel(tone: HUD.primary)
            .frame(maxWidth: 460)
        }
    }

    // MARK: The world

    private var world: some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDSection(title: "Today", code: "CAL.01", first: true) {
                today
            }
            HUDSection(title: "Inbox", code: "MSG.12") {
                let inbox: [Event.Source] = [.imessage, .sms, .email]
                HUDSparkline(
                    label: "Per hour", data: Array(activity.hours(inbox).suffix(16)),
                    display: "\(Int(activity.today(inbox).reduce(0, +))) today",
                    variant: .bars, tone: HUD.accent
                )
            }
            HUDSection(title: "Collectors", code: "COL.01") {
                collectors
            }
        }
    }

    /// Today's (or, after 5 pm, tomorrow's) calendar and reminders, straight from Calendar and Reminders; then what's
    /// coming up from memory and the public weather and flight lines.
    @ViewBuilder private var today: some View {
        let tomorrow = !Calendar.current.isDateInToday(model.scheduleDay)
        let rows = BriefPresentation.today(
            occurrences: model.todayOccurrences, reminders: model.todayReminders,
            now: tomorrow ? model.scheduleDay : Date(), calendar: .current
        )
        let overdue = rows.filter { $0.kind == .overdue }.count
        VStack(alignment: .leading, spacing: HUD.space3) {
            HStack(spacing: HUD.space4) {
                HUDReadout(label: tomorrow ? "Tomorrow" : "First", value: rows.first?.time ?? "----")
                HUDReadout(label: "Items", value: model.isSample ? "----" : "\(rows.count)")
            }
            HUDTag(word: overdue > 0 ? "\(overdue) overdue" : rows.isEmpty ? "Clear" : "On track", tone: overdue > 0 ? HUD.warn : HUD.ok)
            ForEach(Array(rows.prefix(wholeDay ? rows.count : 4).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: HUD.space2) {
                    Text(row.time).hudType(.data).foregroundStyle(row.kind == .overdue ? HUD.warn : HUD.inkMuted).frame(
                        width: 58,
                        alignment: .leading
                    )
                    Text(row.title).lineLimit(1)
                    if row.prepID != nil {
                        Spacer(minLength: HUD.space1)
                        Button("Prep") { Task { await model.prep(row) } }
                            .buttonStyle(HUDChipStyle())
                            .help("What's recent with the people in this meeting")
                    }
                }
            }
            if rows.count > 4 {
                Button(wholeDay ? "Fewer" : "\(rows.count - 4) more") { wholeDay.toggle() }
                    .buttonStyle(HUDChipStyle(muted: true))
            }
            let upcoming = MemoryBook(notes: model.memories).upcoming(now: Date(), calendar: .current)
            ForEach(upcoming, id: \.note.id) { item in
                Text(item.line).hudType(.caption).foregroundStyle(item.days <= 1 ? HUD.warn : HUD.inkMuted)
            }
            ForEach(WorldPresence.shared.briefLines, id: \.self) { line in
                Text(line).hudType(.caption).foregroundStyle(HUD.inkMuted)
            }
        }
    }

    /// Each source Aegis reads, live or not, with the one-click fix when one needs it (#186).
    private var collectors: some View {
        VStack(alignment: .leading, spacing: HUD.space3) {
            ForEach(model.stored?.coverage ?? [], id: \.source) { coverage in
                let state = CollectorState(coverage, health: model.health)
                HUDMeter(
                    label: coverage.source.rawValue.capitalized, value: state.value, display: state.word, size: .small, tone: state.tone
                )
            }
            ForEach(model.health, id: \.source) { line in
                HealthFix(line: line)
            }
        }
    }
}

/// How a source reads on its meter: live, degraded or offline.
private struct CollectorState {
    let word: String
    let value: Double
    let tone: HUDColor

    init(_ coverage: SourceCoverage, health: [SourceHealth.Line]) {
        let unwell = health.contains { $0.source == coverage.source } || ![.ok, .noData].contains(coverage.status)
        let broken = [.permissionDenied, .notFound, .formatChanged, .unreadable].contains(coverage.status)
        (word, value, tone) = !unwell ? ("Live", 1, HUD.ok) : broken ? ("Offline", 0.15, HUD.critical) : ("Degraded", 0.5, HUD.warn)
    }
}

/// A source that needs attention and its one-click fix (#186). Shown only inside the open panel.
struct HealthFix: View {
    let line: SourceHealth.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HUD.space2) {
            Text(BriefPresentation.health(line)).hudType(.caption).foregroundStyle(HUD.warn)
            switch line.fix {
            case .openPrivacySettings:
                Button("Privacy") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(HUDChipStyle())
                .help("Open Privacy settings")
            case .startMail:
                Button("Start Mail") {
                    guard let mail = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") else { return }
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = false
                    config.hides = true
                    NSWorkspace.shared.openApplication(at: mail, configuration: config)
                }
                .buttonStyle(HUDChipStyle())
            case .none:
                EmptyView()
            }
        }
    }
}
