import AegisKit
import SwiftUI

/// 05 LOGS, the long-running record: everything Aegis did, noted and changed, newest first, with filters; what it
/// remembers on the right; and its storage on this Mac below. Action records hold codes only, never content.
struct LogsScreen: View {
    let model: PanelModel
    @Binding var screen: HUDScreen
    @State private var filter = Filter.all
    @State private var actions: [ActionLogEntry] = []
    @State private var storage: UInt64?
    @State private var skills: [SkillManifest] = []
    @State private var activity = ActivityPresence.shared

    enum Filter: String, CaseIterable {
        case all = "All", actions = "Actions", memory = "Memory", warnings = "Warnings", errors = "Errors"
    }

    var body: some View {
        HUDShell {
            HUDTopBar(model: model, screen: $screen)
        } content: {
            HStack(alignment: .top, spacing: HUD.space8) {
                log.frame(maxWidth: .infinity, maxHeight: .infinity).hudHub()
                ScrollView { memory }.scrollIndicators(.never).frame(width: 330)
            }
        } bottom: {
            HStack(alignment: .bottom, spacing: HUD.space6) {
                let disk = SystemMonitor.shared.reading.diskTotal
                HUDMeter(
                    label: "Aegis on this Mac", value: Double(storage ?? 0) / Double(max(disk, 1)),
                    display: storage.map { HUDFormat.bytes(Double($0)) } ?? "----"
                )
                .frame(maxWidth: .infinity)
                let coverage = model.stored?.coverage ?? []
                let live = coverage.filter { [.ok, .noData].contains($0.status) }.count
                HUDCharMeter(
                    value: coverage.isEmpty ? 0 : Double(live) / Double(coverage.count), display: "SOURCES \(live)/\(coverage.count) LIVE",
                    tone: HUD.accent
                )
                .frame(width: 300, alignment: .trailing)
            }
        }
        .task {
            await model.refreshActivity()
            actions = await (try? model.actions?.entries()) ?? []
            // The sample shows synthetic data only, never what's on this Mac.
            guard !model.isSample else { return }
            skills = PanelModel.skillBook().skills
            storage = await Task.detached(priority: .utility) { Self.folderSize() }.value
        }
    }

    // MARK: The activity log

    private var log: some View {
        let rows = entries.filter(matches)
        let collected = Int(activity.total.reduce(0, +))
        return HUDSection(title: "Activity log", code: "\(collected) COLLECTED · 24 H", first: true, linked: false) {
            HStack(spacing: HUD.space2) {
                ForEach(Filter.allCases, id: \.self) { option in
                    Button(option.rawValue) { filter = option }
                        .buttonStyle(.plain)
                        .hudType(.label)
                        .foregroundStyle(filter == option ? HUD.ink : HUD.inkMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .overlay(Rectangle().strokeBorder(filter == option ? HUD.primary : HUD.glassEdge, lineWidth: 1))
                        .accessibilityAddTraits(filter == option ? .isSelected : [])
                }
            }
            .padding(.bottom, HUD.space1)
            Text("// TODAY · " + Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased())
                .hudType(.caption).foregroundStyle(HUD.inkMuted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.prefix(200).enumerated()), id: \.offset) { index, row in
                        HUDLogRow(
                            time: Self.clock.string(from: row.time),
                            source: row.source,
                            level: row.level,
                            message: row.message
                        )
                        // Rows type out 40 ms apart.
                        .hudArrive(.type, after: 0.2 + HUDMotion.stagger(index, 0.04))
                    }
                    if rows.isEmpty {
                        Text("Nothing logged yet.").hudType(.caption).foregroundStyle(HUD.inkMuted)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    /// Log times read as a terminal's, to the second.
    private static let clock = {
        let format = DateFormatter()
        format.dateFormat = "HH:mm:ss"
        return format
    }()

    /// A source's short name for the log's source column.
    private static func name(_ source: SourceKind) -> String {
        source == .notifications ? "notices" : source.rawValue
    }

    private struct Entry {
        let time: Date
        let source: String
        let level: HUDLogRow.Level
        let message: String
    }

    private func matches(_ entry: Entry) -> Bool {
        switch filter {
        case .all: true
        case .actions: entry.level == .act
        case .memory: entry.level == .mem
        case .warnings: entry.level == .warn
        case .errors: entry.level == .err
        }
    }

    /// The record, merged from Aegis's own feeds, newest first.
    private var entries: [Entry] {
        var rows = actions.map { action in
            let level: HUDLogRow.Level = switch action.outcomeCode {
            case .succeeded, .undone: .act
            case .failed, .undoUnavailable: .err
            case .rejected, .cancelled: .warn
            case .proposed, .awaitingConfirmation: .info
            }
            return Entry(time: action.time, source: action.domain.rawValue, level: level, message: Self.words(action))
        }
        rows += model.done.map { Entry(time: $0.time, source: "done", level: .ok, message: $0.text) }
        rows += model.memories.map { note in
            let verb = note.origin == .quarantined ? "flagged" : note.origin == .reflected ? "observed"
                : note.isLearned ? "learned" : "stored"
            return Entry(time: note.createdAt, source: "memory", level: .mem, message: verb + ": " + note.text)
        }
        if let stored = model.stored {
            rows.append(Entry(
                time: stored.storedAt, source: model.personality.name, level: .ok,
                message: "brief written · \(stored.brief.model ?? "model") · \(stored.brief.items.count) items"
                    + (stored.brief.omittedEvents > 0 ? " · \(stored.brief.omittedEvents) not read" : "")
            ))
            rows += stored.coverage.compactMap { coverage in
                coverage.lastSuccess.map {
                    Entry(time: $0, source: Self.name(coverage.source), level: .info, message: "scanned · \(coverage.events) new")
                }
            }
        }
        rows += model.health.map { Entry(time: Date(), source: Self.name($0.source), level: .warn, message: BriefPresentation.health($0)) }
        return rows.sorted { $0.time > $1.time }
    }

    /// An action record in plain words: what kind, at which tier, and how it ended.
    private static func words(_ action: ActionLogEntry) -> String {
        let outcome = switch action.outcomeCode {
        case .proposed: "proposed"
        case .rejected: "refused by the safety rules"
        case .awaitingConfirmation: "waiting for you to confirm"
        case .cancelled: "cancelled"
        case .succeeded: "done"
        case .failed: "failed"
        case .undone: "undone"
        case .undoUnavailable: "couldn't be undone"
        }
        return "\(action.domain.rawValue) action · \(action.decision.tier.rawValue) · \(outcome)"
    }

    // MARK: Memory

    private var memory: some View {
        let notes = model.memories
        let today = Calendar.current.startOfDay(for: Date())
        let groups: [(String, [MemoryNote])] = [
            ("Facts", notes.filter { $0.kind == .fact && !$0.isLearned && $0.origin != .quarantined }),
            ("Preferences", notes.filter { $0.kind == .preference && !$0.isLearned && $0.origin != .quarantined }),
            ("Shortcuts", notes.filter { $0.kind == .shortcut }),
            ("Learned today", notes.filter { $0.isLearned && $0.origin != .reflected && $0.createdAt >= today }),
            ("Learned", notes.filter { $0.isLearned && $0.origin != .reflected && $0.createdAt < today }),
            ("Observations", notes.filter { $0.origin == .reflected }),
            ("Flagged", notes.filter { $0.origin == .quarantined }),
        ]
        return HUDSection(title: "Memory", code: "\(notes.count) NOTES", first: true, linked: false) {
            HUDAsciiArt(shape: .helix, cols: 40, rows: 7, tone: HUD.accent, label: "Aegis's memory")
                .frame(maxWidth: .infinity)
                .padding(.bottom, HUD.space2)
            ForEach(groups.filter { !$0.1.isEmpty }, id: \.0) { title, members in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).hudType(.label).foregroundStyle(HUD.accent)
                        Spacer()
                        Text(title == "Learned today" ? "+\(members.count)" : "\(members.count)").hudType(.caption)
                            .foregroundStyle(HUD.inkMuted)
                    }
                    .padding(.bottom, HUD.space1)
                    ForEach(members) { note in
                        memoryRow(note)
                    }
                }
                .padding(.vertical, HUD.space2)
                .overlay(alignment: .bottom) { HUDRule() }
            }
            if !skills.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Skills").hudType(.label).foregroundStyle(HUD.accent)
                        Spacer()
                        Text("\(skills.count)").hudType(.caption).foregroundStyle(HUD.inkMuted)
                    }
                    .padding(.bottom, HUD.space1)
                    ForEach(skills, id: \.name) { skill in
                        line(skill.name + " · \(skill.steps.count) steps" + (skill.schedule.map { _ in " · scheduled" } ?? ""))
                    }
                }
                .padding(.vertical, HUD.space2)
            }
            if notes.isEmpty, skills.isEmpty {
                Text("Nothing remembered yet. Say “remember that…”.").hudType(.caption).foregroundStyle(HUD.inkMuted)
            }
        }
    }

    /// One note, forgotten with one click (#222, #282).
    private func memoryRow(_ note: MemoryNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HUD.space2) {
            line(note.kind == .shortcut ? "“\(note.trigger ?? "")” → \(note.text)" : note.text)
                .strikethrough(note.origin == .quarantined)
                .help(note.origin == .quarantined ? "Flagged: looked like an instruction, never used"
                    : note.origin == .reflected ? "Aegis's observation from your notes; may be wrong"
                    : note.isLearned ? "Learned from our chats" : "You asked me to remember this")
            Spacer(minLength: HUD.space2)
            Button("✕") { Task { await model.forget(note) } }
                .buttonStyle(.plain).foregroundStyle(HUD.inkMuted).help("Forget this").accessibilityLabel("Forget")
        }
    }

    private func line(_ text: String) -> some View {
        (Text("> ").foregroundStyle(HUD.inkMuted) + Text(text).foregroundStyle(HUD.ink))
            .font(.custom(HUDType.body.fontName, size: 11))
            .lineLimit(2)
    }

    // MARK: Storage

    /// How much Aegis keeps in its own folder: models, the database, memory and settings. Sizes only.
    private nonisolated static func folderSize() -> UInt64? {
        guard let folder = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("Aegis", isDirectory: true),
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return nil }
        var total: UInt64 = 0
        for case let file as URL in files {
            total += UInt64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
