import AegisKit
import AppKit
import SwiftUI

/// 03 COMMS, everything Aegis collected, as a feed: the sources and devices on the left, the brief and who's waiting
/// in the centre, Aegis's summary and what it filed on the right, and today's notifications per hour below.
struct CommsScreen: View {
    let model: PanelModel
    @Binding var screen: HUDScreen
    @State private var activity = ActivityPresence.shared
    /// Feed rows opened to show their messages.
    @State private var open: Set<String> = []
    @State private var filteredOpen = false

    var body: some View {
        HUDShell {
            HUDTopBar(model: model, screen: $screen)
        } content: {
            HStack(alignment: .top, spacing: HUD.space8) {
                sources.frame(width: 200)
                ScrollView {
                    feed.padding(.trailing, HUD.space2)
                }
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity)
                summary.frame(width: 270)
            }
        } bottom: {
            let notifications = activity.today([.notification])
            HUDSparkline(
                label: "Notifications per hour · today", data: notifications, display: "\(Int(notifications.reduce(0, +))) today",
                variant: .bars, tone: HUD.accent, columns: max(notifications.count, 2), height: 56
            )
        }
        .task(id: HUDPresence.shared.open) {
            // Each time the panel opens: the counts move on while it's closed, and this view stays alive.
            guard HUDPresence.shared.open else { return }
            await model.refreshActivity()
            // The first message each brief item cites, once, to show where and when it came from.
            await model.loadSources(ids: (model.stored?.brief.items ?? []).compactMap(\.eventIDs.first))
        }
    }

    // MARK: Sources and devices

    private var sources: some View {
        let live = (model.stored?.coverage ?? []).filter { [.ok, .noData].contains($0.status) }.count
        let rows: [(String, Int)] = [
            ("All", Int(activity.today().reduce(0, +))),
            ("Messages", Int(activity.today([.imessage, .sms]).reduce(0, +))),
            ("Mail", Int(activity.today([.email]).reduce(0, +))),
            ("Notifications", Int(activity.today([.notification]).reduce(0, +))),
            ("Calendar", model.todayOccurrences.count),
            ("Reminders", model.todayReminders.count),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            HUDSection(title: "Sources", code: "\(live) LIVE", first: true) {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.0) { name, count in
                        HStack(alignment: .firstTextBaseline) {
                            Text(name).hudType(.label).foregroundStyle(name == "All" ? HUD.ink : HUD.inkMuted)
                            Spacer()
                            Text("\(count)").hudType(.data).foregroundStyle(name == "All" ? HUD.primary : HUD.ink)
                                .hudGlow(active: name == "All")
                        }
                        .padding(.vertical, 5)
                        .overlay(alignment: .bottom) { HUDRule() }
                    }
                }
            }
        }
    }

    // MARK: The feed

    /// The feed; arriving, its items slide in from the left 50 ms apart, top to bottom.
    private var feed: some View {
        let sections = model.stored.map { BriefPresentation.sections($0.brief) } ?? []
        let briefed = sections.reduce(0) { $0 + $1.entries.count }
        let people = Array(model.people.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            switch model.phase {
            case .loading:
                group("// Loading")
            case let .unavailable(reason):
                group("// " + reason)
            case .ready:
                ForEach(Array(sections.enumerated()), id: \.element.priority) { number, section in
                    let before = sections.prefix(number).reduce(0) { $0 + $1.entries.count }
                    group("// " + BriefPresentation.heading(section.priority))
                    ForEach(Array(section.entries.enumerated()), id: \.offset) { offset, entry in
                        Group {
                            switch entry {
                            case let .item(item): itemRow(item)
                            case let .person(person, items): personRow(person, items: items)
                            }
                        }
                        .hudArrive(.slide, after: HUDMotion.stagger(before + offset, 0.05))
                    }
                }
            }
            if !people.isEmpty {
                group("// People waiting")
                ForEach(Array(people.enumerated()), id: \.element.person.id) { offset, waiting in
                    waitingRow(waiting).hudArrive(.slide, after: HUDMotion.stagger(briefed + offset, 0.05))
                }
            }
            if !model.commitments.isEmpty {
                group("// You said you'd")
                ForEach(Array(model.commitments.prefix(5).enumerated()), id: \.element.eventID) { offset, promise in
                    promiseRow(promise).hudArrive(.slide, after: HUDMotion.stagger(briefed + people.count + offset, 0.05))
                }
            }
            filtered
        }
    }

    private func group(_ title: String) -> some View {
        Text(title.uppercased()).hudType(.caption).foregroundStyle(HUD.inkMuted).padding(.top, HUD.space3)
    }

    private static func tone(_ priority: Brief.Priority) -> HUDColor {
        switch priority {
        case .urgent: HUD.critical
        case .reply: HUD.primary
        case .fyi: HUD.frame
        }
    }

    /// Where a message came from, as the feed's source line names it.
    private static func source(_ event: Event?) -> String {
        guard let event else { return "Brief" }
        return switch event.source {
        case .email: "Mail"
        case .imessage: "iMessage"
        case .sms: "SMS"
        case .notification: SourcePresentation.appName(event.appID)?.capitalized ?? "Notification"
        }
    }

    private func toggle(_ key: String, load ids: [String]) {
        if open.contains(key) {
            open.remove(key)
        } else {
            open.insert(key)
            Task { await model.loadSources(ids: ids) }
        }
    }
}

extension CommsScreen {
    /// One brief item: click to show the messages it's based on, each with Open (and Junk for strangers).
    private func itemRow(_ item: Brief.Item) -> some View {
        let key = item.eventIDs.joined(separator: ",")
        let event = item.eventIDs.first.flatMap { model.sources[$0] }
        return HUDNotification(
            source: Self.source(event), device: "Mac",
            time: event.map { SourcePresentation.when($0.eventTime, now: Date(), calendar: .current) },
            title: item.person?.name ?? item.text, text: item.person == nil ? nil : item.text,
            tone: Self.tone(item.priority), unread: item.priority != .fyi,
            tag: item.priority == .urgent ? HUDTag(word: "Urgent", tone: HUD.critical) : nil,
            action: { toggle(key, load: item.eventIDs) },
            detail: {
                if open.contains(key) {
                    sources(item.eventIDs, accent: Self.tone(item.priority))
                    if let person = item.person {
                        muteButton(person)
                    }
                }
            }
        )
    }

    /// A person's items folded into one row; opened, each item and its messages.
    private func personRow(_ person: Brief.Person, items: [Brief.Item]) -> some View {
        let key = "person:" + person.id
        let urgent = items.contains { $0.priority == .urgent }
        return HUDNotification(
            source: "Brief", device: "Mac", title: person.name, text: "\(items.count) things",
            tone: urgent ? HUD.critical : HUD.primary, unread: true,
            tag: urgent ? HUDTag(word: "Urgent", tone: HUD.critical) : nil,
            action: { toggle(key, load: items.flatMap(\.eventIDs)) },
            detail: {
                if open.contains(key) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Text(item.text).foregroundStyle(HUD.ink).padding(.top, HUD.space1)
                        sources(item.eventIDs, accent: Self.tone(item.priority))
                    }
                    muteButton(person)
                }
            }
        )
    }

    @ViewBuilder private func sources(_ ids: [String], accent: HUDColor) -> some View {
        if model.loadedSources.contains(ids) || ids.allSatisfy({ model.sources[$0] != nil }) {
            ForEach(ids, id: \.self) { id in
                if let event = model.sources[id] {
                    SourceRow(
                        event: event, accent: accent,
                        onJunk: BriefPresentation.junkHandle(event) == nil ? nil : { Task { await model.markJunk(event) } }
                    )
                } else {
                    Text("No longer stored.").hudType(.caption).foregroundStyle(HUD.inkMuted)
                }
            }
        } else {
            Text("Loading…").hudType(.caption).foregroundStyle(HUD.inkMuted)
        }
    }

    /// "Mute <name>": keeps a person or group chat out of the brief, People waiting and the glow (#175).
    private func muteButton(_ person: Brief.Person) -> some View {
        Button("Mute " + person.name) { Task { await model.mute(person) } }
            .buttonStyle(HUDChipStyle(muted: true))
            .help("Leave " + person.name + " out of the brief until you unmute them")
            .padding(.top, HUD.space1)
    }

    /// Who is waiting on you (#165), longest first; opened, their messages and a reply draft to copy (#176).
    private func waitingRow(_ waiting: PersonWaiting) -> some View {
        let key = "waiting:" + waiting.person.id
        return HUDNotification(
            source: "Waiting", device: "Mac", time: BriefPresentation.waiting(since: waiting.waitingSince, now: Date()),
            title: waiting.person.name, text: waiting.questions == 1 ? "1 question" : "\(waiting.questions) questions",
            tone: HUD.warn, unread: true, action: { toggle(key, load: waiting.eventIDs) },
            detail: {
                if open.contains(key) {
                    sources(waiting.eventIDs, accent: HUD.warn)
                    DraftReply(model: model, waiting: waiting)
                }
            }
        )
    }

    /// A promise from the owner's own messages that still looks open (#182).
    private func promiseRow(_ promise: Commitment) -> some View {
        let key = "promise:" + promise.eventID
        let late = promise.due.map { $0 < Date() } ?? false
        return HUDNotification(
            source: "Promise", device: "Mac", time: BriefPresentation.due(promise.due, now: Date(), calendar: .current),
            title: promise.person, text: "“" + promise.text + "”", tone: late ? HUD.warn : HUD.primary, unread: late,
            action: { toggle(key, load: [promise.eventID]) },
            detail: {
                if open.contains(key) {
                    sources([promise.eventID], accent: late ? HUD.warn : HUD.primary)
                }
            }
        )
    }

    /// What Aegis kept out as junk (#167) and who is muted (#175), each with its way back.
    @ViewBuilder private var filtered: some View {
        if !model.filtered.isEmpty || !model.rules.muted.isEmpty {
            Button {
                filteredOpen.toggle()
            } label: {
                group((filteredOpen ? "// ▾ " : "// ▸ ") + BriefPresentation.filteredHeading(
                    hidden: model.filtered.reduce(0) { $0 + $1.count }, muted: model.rules.muted.count
                ))
            }
            .buttonStyle(.plain)
            if filteredOpen {
                ForEach(model.filtered, id: \.handle) { sender in
                    HUDNotification(
                        source: BriefPresentation.reason(sender.reason), time: "\(sender.count)", title: sender.sender, text: sender.latest
                    ) {
                        Button("Not junk") { Task { await model.trust(sender) } }.buttonStyle(HUDChipStyle()).padding(.top, HUD.space1)
                    }
                }
                ForEach(model.rules.muted.sorted { $0.value < $1.value }, id: \.key) { id, name in
                    HUDNotification(source: "Muted", title: name) {
                        Button("Unmute") { Task { await model.unmute(id) } }.buttonStyle(HUDChipStyle()).padding(.top, HUD.space1)
                    }
                }
            }
        }
    }

    // MARK: Summary and filing

    private var summary: some View {
        let collected = activity.today().reduce(0, +)
        let briefed = Double(model.stored?.brief.items.count ?? 0)
        let hidden = Double(model.filtered.reduce(0) { $0 + $1.count })
        let scale = max(collected, briefed + hidden, 1)
        return VStack(alignment: .leading, spacing: 0) {
            HUDSection(title: "\(model.personality.name) summary", code: "AI.SUM", first: true) {
                HUDAsciiArt(shape: .eye, cols: 30, rows: 10, label: "Aegis watching")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HUD.space2)
                Text(model.stored.map { BriefPresentation.spoken($0.brief, now: Date(), calendar: .current) } ?? "Nothing collected yet.")
                    .foregroundStyle(HUD.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HUDSection(title: "Filed today", code: "AUTO", index: 1) {
                VStack(spacing: HUD.space3) {
                    HUDMeter(label: "In the brief", value: briefed / scale, display: "\(Int(briefed))")
                    HUDMeter(label: "Filtered", value: hidden / scale, display: "\(Int(hidden))", tone: HUD.accent)
                    HUDMeter(label: "Needs you", value: Double(model.needsYou) / scale, display: "\(model.needsYou)", tone: HUD.warn)
                }
            }
        }
    }
}

/// "Draft reply" for someone waiting (#176): the local model's suggestion, to copy and send yourself.
struct DraftReply: View {
    let model: PanelModel
    let waiting: PersonWaiting

    var body: some View {
        switch model.drafts[waiting.person.id] {
        case .drafting:
            Text("Drafting a reply…").hudType(.caption).foregroundStyle(HUD.inkMuted)
        case let .ready(draft):
            VStack(alignment: .leading, spacing: HUD.space2) {
                Text("DRAFT · you send it").hudType(.data).foregroundStyle(HUD.inkMuted)
                Text(draft.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: HUD.space2) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft.text, forType: .string)
                    }
                    if let id = waiting.eventIDs.first, let event = model.sources[id], let link = EventLink.link(for: event) {
                        Button("Open chat") { SourcePresentation.open(link) }
                    }
                    Button("Redraft") { Task { await model.draftReply(waiting.person) } }
                }
                .buttonStyle(HUDChipStyle())
            }
            .padding(HUD.space2)
            .overlay(Rectangle().strokeBorder(HUD.line, lineWidth: HUD.strokeHair))
        case let .failed(message):
            HStack(spacing: HUD.space2) {
                Text(message).hudType(.caption).foregroundStyle(HUD.inkMuted)
                Button("Try again") { Task { await model.draftReply(waiting.person) } }.buttonStyle(HUDChipStyle())
            }
        case nil:
            Button("Draft reply") { Task { await model.draftReply(waiting.person) } }.buttonStyle(HUDChipStyle())
        }
    }
}
