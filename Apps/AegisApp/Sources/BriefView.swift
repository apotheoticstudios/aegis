import AegisKit
import AppKit
import SwiftUI

/// The HUD panel (concept A, #292): the owner's day on the left, the reactor and conversation in the centre, the
/// brief on the right, in frosted glass with hard edges, cyan and amber.
struct BriefView: View {
    let model: PanelModel
    let close: () -> Void
    /// Items opened to show their sources, by their cited IDs.
    @State private var expanded: Set<[String]> = []
    @State private var openPeople: Set<String> = []
    @State private var question = ""
    @State var openAnswers: Set<UUID> = []
    @State private var openWaiting: Set<String> = []
    @State private var filteredOpen = false
    @State var openCommitments: Set<String> = []
    @State var openDone: Set<String> = []

    static let cyan = Color(red: 0.35, green: 0.85, blue: 1.0)
    private static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)

    var body: some View {
        Group {
            if WorldPresence.shared.inPanel {
                WorldScreen(model: model)
            } else {
                VStack(spacing: 0) {
                    topBar
                    HStack(alignment: .top, spacing: 20) {
                        leftColumn.frame(width: 330)
                        centreColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                        rightColumn.frame(width: 380)
                    }
                    .padding(20)
                }
                .frame(minWidth: 1120, minHeight: 700, alignment: .topLeading)
            }
        }
        .background(HUDBackdrop())
        .environment(\.colorScheme, .dark)
        // Escape is God's Eye View's own while the globe shows (#303).
        .onExitCommand {
            if !WorldPresence.shared.inPanel {
                close()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            if model.stored != nil {
                Button(model.voice.speaking ? "■ STOP" : "▶ READ") { model.readBrief() }
                    .buttonStyle(.plain).font(.system(.caption, design: .monospaced)).foregroundStyle(Self.cyan)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(Rectangle().strokeBorder(Self.cyan.opacity(0.5), lineWidth: 1))
                    .help("Aegis reads the brief aloud")
            }
            Button("◉ WORLD") { WorldWindow.shared.show() }
                .buttonStyle(.plain).font(.system(.caption, design: .monospaced)).foregroundStyle(Self.cyan)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(Rectangle().strokeBorder(Self.cyan.opacity(0.5), lineWidth: 1))
                .help("The live globe inside Aegis; steer it by talking to Aegis")
            Text(BriefPresentation.title(storedAt: model.stored?.storedAt, now: Date(), calendar: .current))
                .font(.system(.title3, design: .monospaced).weight(.semibold)).foregroundStyle(Self.cyan)
            if model.isSample {
                Text("SAMPLE").font(.system(.caption, design: .monospaced)).padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(Rectangle().strokeBorder(Self.amber, lineWidth: 1)).foregroundStyle(Self.amber)
            }
            Spacer()
            if model.writing {
                Text("WRITING A FRESH BRIEF…").font(.system(.caption, design: .monospaced)).foregroundStyle(Self.cyan)
            } else if let notice = model.notice {
                Text(notice).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            if let stored = model.stored {
                Text(BriefPresentation.written(stored.storedAt, now: Date(), calendar: .current))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    /// Today's calendar and reminders, straight from Calendar and Reminders (never via the model).
    @ViewBuilder private var todaySection: some View {
        let tomorrow = !Calendar.current.isDateInToday(model.scheduleDay)
        let rows = BriefPresentation.today(
            occurrences: model.todayOccurrences, reminders: model.todayReminders,
            now: tomorrow ? model.scheduleDay : Date(), calendar: .current
        )
        if !model.isSample {
            VStack(alignment: .leading, spacing: 6) {
                Text(tomorrow ? "TOMORROW" : "TODAY").font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Self.cyan)
                if rows.isEmpty {
                    Text("Nothing scheduled.").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.time)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(row.kind == .overdue ? Self.amber : .secondary)
                            .frame(width: 92, alignment: .leading)
                        Text(row.title).fixedSize(horizontal: false, vertical: true)
                        if let detail = row.detail, !detail.isEmpty {
                            Text("· " + detail).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        if row.prepID != nil {
                            Spacer(minLength: 8)
                            Button("Prep") { Task { await model.prep(row) } }
                                .buttonStyle(.plain).font(.system(.caption, design: .monospaced)).foregroundStyle(Self.cyan)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .overlay(Rectangle().strokeBorder(Self.cyan.opacity(0.5), lineWidth: 1))
                                .help("What's recent with the people in this meeting")
                        }
                    }
                }
            }
            .hudPanel()
        }
    }

    /// Ask Aegis anything (#163): Return sends; answers come only from the owner's own data on the Mac.
    @ViewBuilder private var askBar: some View {
        HStack(spacing: 10) {
            Text(">_").font(.system(.body, design: .monospaced)).foregroundStyle(Self.cyan)
            TextField("Ask Aegis about your messages, email or calendar…", text: $question)
                .textFieldStyle(.plain).font(.system(size: 16))
                .onSubmit {
                    Task { await model.submit(question) }
                }
            if case .asking = model.askState {
                Text("THINKING…").font(.system(.caption, design: .monospaced)).foregroundStyle(Self.cyan)
            }
            micButton
        }
        .padding(.horizontal, 16).frame(height: 48)
        .background(.ultraThinMaterial, in: HUDChamfer())
        .overlay(alignment: .top) { Rectangle().fill(Self.cyan).frame(height: 1).padding(.leading, 10) }
        .onChange(of: model.voice.state) { _, state in
            if case let .listening(words) = state {
                question = words
            }
        }
        proposalView
        if case let .unavailable(reason) = model.voice.state {
            HStack(spacing: 8) {
                Text(reason).font(.system(.caption, design: .monospaced)).foregroundStyle(Self.amber)
                Button("✕") { model.voice.dismissNotice() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    /// Who is waiting on you (#165): longest first, each opening to their questions and sources.
    @ViewBuilder private var peopleSection: some View {
        if !model.people.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("PEOPLE WAITING").font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(Self.cyan)
                ForEach(model.people.prefix(5), id: \.person.id) { waiting in
                    let open = openWaiting.contains(waiting.person.id)
                    Button {
                        if open {
                            openWaiting.remove(waiting.person.id)
                        } else {
                            openWaiting.insert(waiting.person.id)
                            Task { await model.loadSources(ids: waiting.eventIDs) }
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(BriefPresentation.waiting(since: waiting.waitingSince, now: Date()))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(Self.amber)
                                .frame(width: 56, alignment: .leading)
                            Text(waiting.person.name).fontWeight(.semibold)
                            Text("· " + (waiting.questions == 1 ? "1 question" : "\(waiting.questions) questions"))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(open ? "▾" : "▸").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if open {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(waiting.eventIDs, id: \.self) { id in
                                if let event = model.sources[id] {
                                    SourceRow(event: event, accent: Self.amber)
                                }
                            }
                            draftView(waiting)
                        }
                        .padding(.leading, 66)
                    }
                }
                if model.people.count > 5 {
                    Text("+\(model.people.count - 5) more").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .hudPanel()
        }
    }

    private func sectionView(_ section: BriefPresentation.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(BriefPresentation.heading(section.priority))
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(section.priority == .urgent ? Self.amber : Self.cyan)
            ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case let .item(item):
                    itemView(item, accent: accent(item.priority))
                case let .person(person, items):
                    personView(person, items: items, accent: accent(entry.priority))
                }
            }
        }
    }

    private func accent(_ priority: Brief.Priority) -> Color {
        priority == .urgent ? Self.amber : Self.cyan
    }

    /// One person's items under their name: click to show each, with its own sources.
    private func personView(_ person: Brief.Person, items: [Brief.Item], accent: Color) -> some View {
        let open = openPeople.contains(person.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if open {
                    openPeople.remove(person.id)
                } else {
                    openPeople.insert(person.id)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Rectangle().fill(accent).frame(width: 6, height: 6)
                    Text(person.name).fontWeight(.semibold)
                    Text("· \(items.count) things").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(open ? "▾" : "▸").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        itemView(item, accent: self.accent(item.priority), muteHere: false)
                    }
                    muteButton(person)
                }
                .padding(.leading, 16)
            }
        }
    }

    /// One item: click to show the messages it's based on, each with Open.
    private func itemView(_ item: Brief.Item, accent: Color, muteHere: Bool = true) -> some View {
        let open = expanded.contains(item.eventIDs)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if open {
                    expanded.remove(item.eventIDs)
                } else {
                    expanded.insert(item.eventIDs)
                    Task { await model.loadSources(for: item) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Rectangle().fill(accent).frame(width: 6, height: 6)
                    Text(item.text).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Text((open ? "▾ " : "▸ ") + (item.eventIDs.count == 1 ? "1 source" : "\(item.eventIDs.count) sources"))
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    if model.loadedSources.contains(item.eventIDs) {
                        ForEach(item.eventIDs, id: \.self) { id in
                            if let event = model.sources[id] {
                                SourceRow(
                                    event: event, accent: accent,
                                    onJunk: BriefPresentation.junkHandle(event) == nil ? nil : { Task { await model.markJunk(event) } }
                                )
                            } else {
                                Text("No longer stored.").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Loading…").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    if muteHere, let person = item.person {
                        muteButton(person)
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.health, id: \.source) { line in
                healthRow(line)
            }
            Text(model.stored.map { BriefPresentation.coverageLine($0.coverage) } ?? " ")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

/// Concept A's layout (#292): the top bar and the three columns.
extension BriefView {
    private var topBar: some View {
        HStack(spacing: 18) {
            Text(assistant).font(.system(size: 17, weight: .bold, design: .monospaced)).tracking(5)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().second()))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            header
            ForEach(["LOCAL", "PRIVATE"], id: \.self) { chip in
                Text(chip).font(.system(.caption2, design: .monospaced).weight(.semibold)).tracking(1.5)
                    .foregroundStyle(Color(red: 0.49, green: 0.95, blue: 0.75))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color(red: 0.49, green: 0.95, blue: 0.75).opacity(0.14), in: HUDChamfer(cut: 6))
                    .help(chip == "LOCAL" ? "Everything runs on this Mac" : "Your data never leaves this Mac")
            }
        }
        .padding(.horizontal, 20).frame(height: 52)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
    }

    private var leftColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                routineSection
                peopleSection
                todaySection
                comingUpSection
                commitmentsSection
                worldBriefSection
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
    }

    /// The reactor fills the centre and makes room for the conversation.
    private var centreColumn: some View {
        VStack(spacing: 16) {
            if model.askState != .idle {
                ReactorView(mode: reactorMode, size: 120)
                conversationView.hudPanel(lifted: false)
            } else {
                Spacer(minLength: 0)
                ReactorView(mode: reactorMode, size: 380)
                Spacer(minLength: 0)
            }
            askBar
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .loading:
                Text("Loading…").foregroundStyle(.secondary)
            case let .unavailable(reason):
                Text(reason).foregroundStyle(.secondary)
            case .ready:
                if let brief = model.stored?.brief {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(BriefPresentation.sections(brief), id: \.priority) { section in
                                sectionView(section)
                            }
                            doneSection
                            memorySection
                            filteredSection
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .hudPanel()
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The Filtered list and the Mute button (#167, #175), apart from the main body.
extension BriefView {
    /// What Aegis kept out as junk (#167), with "Not junk" for each sender.
    @ViewBuilder private var filteredSection: some View {
        if !model.filtered.isEmpty || !model.rules.muted.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    filteredOpen.toggle()
                } label: {
                    Text((filteredOpen ? "▾ " : "▸ ") + BriefPresentation.filteredHeading(
                        hidden: model.filtered.reduce(0) { $0 + $1.count }, muted: model.rules.muted.count
                    ))
                    .font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if filteredOpen {
                    ForEach(model.filtered, id: \.handle) { sender in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sender.sender + " · " + BriefPresentation.reason(sender.reason) + " · \(sender.count)")
                                    .font(.system(.caption, design: .monospaced))
                                Text(sender.latest).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button("Not junk") { Task { await model.trust(sender) } }
                                .buttonStyle(.plain).font(.system(.caption, design: .monospaced)).foregroundStyle(Self.cyan)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .overlay(Rectangle().strokeBorder(Self.cyan.opacity(0.5), lineWidth: 1))
                        }
                    }
                    ForEach(model.rules.muted.sorted { $0.value < $1.value }, id: \.key) { id, name in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(name + " · Muted").font(.system(.caption, design: .monospaced))
                            Spacer(minLength: 8)
                            Button("Unmute") { Task { await model.unmute(id) } }
                                .buttonStyle(.plain).font(.system(.caption, design: .monospaced)).foregroundStyle(Self.cyan)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .overlay(Rectangle().strokeBorder(Self.cyan.opacity(0.5), lineWidth: 1))
                        }
                    }
                }
            }
        }
    }

    /// "Mute <name>": keeps a person or group chat out of the brief, People waiting and the glow (#175).
    private func muteButton(_ person: Brief.Person) -> some View {
        Button("Mute " + person.name) { Task { await model.mute(person) } }
            .buttonStyle(.plain)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
            .help("Leave " + person.name + " out of the brief until you unmute them")
    }
}

/// Reply drafts for people waiting (#176).
extension BriefView {
    /// "Draft reply" for someone waiting (#176): the local model's suggestion, to copy and send yourself.
    @ViewBuilder private func draftView(_ waiting: PersonWaiting) -> some View {
        switch model.drafts[waiting.person.id] {
        case .drafting:
            Text("Drafting a reply…").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        case let .ready(draft):
            VStack(alignment: .leading, spacing: 6) {
                Text("DRAFT · you send it").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                Text(draft.text).font(.system(.callout)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    smallButton("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft.text, forType: .string)
                    }
                    if let id = waiting.eventIDs.first, let event = model.sources[id], let link = EventLink.link(for: event) {
                        smallButton("Open chat") { SourcePresentation.open(link) }
                    }
                    smallButton("Redraft") { Task { await model.draftReply(waiting.person) } }
                }
            }
            .padding(8)
            .overlay(Rectangle().strokeBorder(Self.cyan.opacity(0.35), lineWidth: 1))
        case let .failed(message):
            HStack(spacing: 8) {
                Text(message).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                smallButton("Try again") { Task { await model.draftReply(waiting.person) } }
            }
        case nil:
            smallButton("Draft reply") { Task { await model.draftReply(waiting.person) } }
        }
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain).font(.system(.caption, design: .monospaced)).foregroundStyle(Self.cyan)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Rectangle().strokeBorder(Self.cyan.opacity(0.5), lineWidth: 1))
    }
}

/// Ask by voice (#178).
extension BriefView {
    /// The reactor's state: listening and speaking from the voice, thinking while Aegis writes or answers.
    var reactorMode: ReactorView.Mode {
        if model.voice.isListening {
            return .listening
        }
        if model.voice.speaking {
            return .speaking
        }
        if case .asking = model.askState {
            return .thinking
        }
        return model.writing ? .thinking : .idle
    }

    /// Ask by voice (#178): click, speak, pause; click again to stop early. On-device only.
    private var micButton: some View {
        Button {
            if model.voice.isListening {
                model.voice.stop()
            } else {
                Task {
                    await model.voice.listen { words in
                        question = words
                        Task { await model.submit(words, spoken: true) }
                    }
                }
            }
        } label: {
            Text(model.voice.isListening ? "■ LISTENING" : "◉ MIC")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(model.voice.isListening ? Self.amber : Self.cyan)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(Rectangle().strokeBorder((model.voice.isListening ? Self.amber : Self.cyan).opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Ask by voice. Recognised on this Mac; nothing is recorded.")
    }
}

/// Plain-language rules (#179): what the owner asked for, one click to apply.
extension BriefView {
    @ViewBuilder var proposalView: some View {
        if let rule = model.proposal {
            HStack(spacing: 8) {
                Text(rule.question).font(.system(.caption, design: .monospaced))
                Spacer(minLength: 8)
                Button(Self.verb(rule.action)) { Task { await model.apply(rule) } }
                    .buttonStyle(.plain).font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(Self.cyan)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(Rectangle().strokeBorder(Self.cyan.opacity(0.6), lineWidth: 1))
                Button("Cancel") { model.dismissProposal() }
                    .buttonStyle(.plain).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(8)
            .overlay(Rectangle().strokeBorder(Self.cyan.opacity(0.35), lineWidth: 1))
        } else if let notice = model.proposalNotice {
            HStack(spacing: 8) {
                Text(notice).font(.system(.caption, design: .monospaced)).foregroundStyle(Self.amber)
                Button("✕") { model.dismissProposal() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    static func verb(_ action: RuleProposal.Action) -> String {
        switch action {
        case .mute: "Mute"
        case .unmute: "Unmute"
        case .junk: "Junk"
        case .notJunk: "Not junk"
        case .vip: "VIP"
        case .unvip: "Not VIP"
        case .keywordUrgent: "Mark urgent"
        case .keywordHide: "Hide"
        case .removeKeyword: "Remove rule"
        }
    }
}

/// Promises you made in your own messages that still look open (#182).
extension BriefView {
    @ViewBuilder var commitmentsSection: some View {
        if !model.commitments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("YOU SAID YOU'D").font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(Self.cyan)
                ForEach(model.commitments.prefix(5), id: \.eventID) { promise in
                    commitmentRow(promise)
                }
                if model.commitments.count > 5 {
                    Text("+\(model.commitments.count - 5) more").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .hudPanel()
        }
    }

    private func commitmentRow(_ promise: Commitment) -> some View {
        let open = openCommitments.contains(promise.eventID)
        let due = BriefPresentation.due(promise.due, now: Date(), calendar: .current)
        let late = promise.due.map { $0 < Date() } ?? false
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if open {
                    openCommitments.remove(promise.eventID)
                } else {
                    openCommitments.insert(promise.eventID)
                    Task { await model.loadSources(ids: [promise.eventID]) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Rectangle().fill(late ? Self.amber : Self.cyan).frame(width: 6, height: 6)
                    Text(promise.person).fontWeight(.semibold)
                    Text("“" + promise.text + "”").foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    if !due.isEmpty {
                        Text(due).font(.system(.caption, design: .monospaced)).foregroundStyle(late ? Self.amber : .secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open, let event = model.sources[promise.eventID] {
                SourceRow(event: event, accent: late ? Self.amber : Self.cyan).padding(.leading, 16)
            }
        }
    }
}

/// What got done today (#211): questions answered, promises kept, reminders completed and meetings held.
extension BriefView {
    @ViewBuilder var doneSection: some View {
        if !model.done.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("DONE TODAY · \(model.done.count)")
                    .font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(Self.cyan)
                ForEach(model.done.prefix(8), id: \.self) { item in
                    doneRow(item)
                }
                if model.done.count > 8 {
                    Text("+\(model.done.count - 8) more").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func doneRow(_ item: DoneItem) -> some View {
        let key = item.kind.rawValue + ":" + (item.eventIDs.first ?? item.scheduleIDs.first ?? item.text)
        let open = openDone.contains(key)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if open {
                    openDone.remove(key)
                } else {
                    openDone.insert(key)
                    if !item.eventIDs.isEmpty {
                        Task { await model.loadSources(ids: item.eventIDs) }
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(Self.cyan.opacity(0.7))
                    Text(item.text).foregroundStyle(.secondary).lineLimit(open ? nil : 1)
                    Spacer(minLength: 8)
                    Text(item.time.formatted(date: .omitted, time: .shortened))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(item.eventIDs.compactMap { model.sources[$0] }, id: \.id) { event in
                    SourceRow(event: event, accent: Self.cyan).padding(.leading, 16)
                }
            }
        }
    }
}

/// A task for Claude or ChatGPT (#235): Start or Cancel, then a running timer with Stop.
extension BriefView {
    /// Aegis's name in the panel, as the owner chose it (#241).
    var assistant: String {
        model.personality.name.uppercased()
    }

    @ViewBuilder var taskControls: some View {
        if ActionPresence.shared.pending != nil {
            HStack(spacing: 14) {
                Button(ActionPresence.shared.pending?.button ?? "Add") { Task { await model.confirmAction() } }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { Task { await model.cancelAction() } }
            }
            .padding(.leading, 60)
        }
        if model.pendingTask != nil {
            HStack(spacing: 14) {
                Button("Start") { Task { await model.startTask() } }.keyboardShortcut(.defaultAction)
                Button("Cancel") { Task { await model.cancelTask() } }
            }
            .padding(.leading, 60)
        }
        if let running = model.runningTask, let started = running.started {
            HStack(spacing: 10) {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(started))
                    Text(
                        "\(assistant) › \(running.request.provider.name) is working on it… \(seconds / 60):\(String(format: "%02d", seconds % 60))"
                    )
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(Self.cyan)
                }
                Button("Stop") { Task { await model.stopTask() } }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }
}

/// Weather at home and today's flight, from public data (#265).
extension BriefView {
    @ViewBuilder var worldBriefSection: some View {
        let lines = WorldPresence.shared.briefLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("WORLD").font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(Self.cyan)
                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: line.hasPrefix("Weather") ? "cloud.sun" : "airplane")
                            .font(.caption).foregroundStyle(Self.cyan.opacity(0.8))
                        Text(line).foregroundStyle(.secondary)
                    }
                }
            }
            .hudPanel()
        }
    }
}

/// Remembered dates in the coming week (#222): "Mum's birthday is 3 March (in 2 days)".
extension BriefView {
    @ViewBuilder var comingUpSection: some View {
        let upcoming = MemoryBook(notes: model.memories).upcoming(now: Date(), calendar: .current)
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("COMING UP").font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(Self.cyan)
                ForEach(upcoming, id: \.note.id) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Rectangle().fill(item.days <= 1 ? Self.amber : Self.cyan).frame(width: 6, height: 6)
                        Text(item.line).foregroundStyle(.secondary)
                    }
                }
            }
            .hudPanel()
        }
    }
}

/// What the owner asked Aegis to remember (#222) and what it learned from chats (#282), forgotten with one click.
extension BriefView {
    /// Shortcut, preference or fact; a sparkle for learned notes, a warning for flagged ones.
    static func memoryIcon(_ note: MemoryNote) -> String {
        if note.origin == .quarantined {
            return "exclamationmark.triangle"
        }
        if note.isLearned {
            return "sparkles"
        }
        return note.kind == .shortcut ? "arrow.turn.down.right" : note.kind == .preference ? "heart" : "bookmark"
    }

    @ViewBuilder var memorySection: some View {
        if !model.memories.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.memories) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: Self.memoryIcon(note))
                                .font(.caption2).foregroundStyle(note.origin == .quarantined ? .orange : Self.cyan.opacity(0.7))
                                .help(note.origin == .quarantined ? "Flagged: looked like an instruction, never used"
                                    : note.origin == .reflected ? "Aegis's observation from your notes; may be wrong"
                                    : note.isLearned ? "Learned from our chats" : "You asked me to remember this")
                            Text(note.kind == .shortcut ? "“\(note.trigger ?? "")” → \(note.text)" : note.text)
                                .foregroundStyle(.secondary).lineLimit(2).strikethrough(note.origin == .quarantined)
                            Spacer(minLength: 8)
                            Button {
                                Task { await model.forget(note) }
                            } label: {
                                Image(systemName: "xmark").font(.caption2)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Forget this")
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("\(assistant) REMEMBERS · \(model.memories.count)")
                    .font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(Self.cyan)
            }
        }
    }
}

/// The conversation with Aegis (#198): every question and reply while the panel is open, newest at the bottom.
extension BriefView {
    var conversationView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("CONVERSATION").font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(Self.cyan)
                Spacer()
                Button("✕ Back to brief") { model.clearAnswer() }
                    .buttonStyle(.plain).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.thread) { exchange in
                            exchangeView(exchange)
                        }
                        if case let .asking(question) = model.askState {
                            line("YOU", question, color: .secondary)
                            Text(model.handingOff.map { "\(assistant) › asking \($0.name)…" }
                                ?? (model.partialAnswer.isEmpty ? "\(assistant) › …" : "\(assistant) › \(model.partialAnswer) …"))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(Self.cyan)
                        }
                        taskControls
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .onChange(of: model.thread.count) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: model.askState) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private func exchangeView(_ exchange: PanelModel.Exchange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            line("YOU", exchange.question, color: .secondary)
            if let answer = exchange.answer {
                line(assistant, answer.text, color: .primary)
                if PanelModel.isHandOff(answer), let model = answer.model {
                    Text("via " + (model.hasPrefix("claude") ? "Claude" : "ChatGPT") + " · "
                        + (model.hasSuffix("-plan") ? "your plan" : model))
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).padding(.leading, 60)
                }
                if let folder = exchange.folder {
                    Button("Open the task's folder") { NSWorkspace.shared.open(folder) }
                        .buttonStyle(.plain).font(.system(.caption, design: .monospaced)).foregroundStyle(Self.cyan)
                        .padding(.leading, 60)
                }
                // Something the owner said about themselves can be remembered with one click (#222).
                if answer.model != "memory", let fact = MemoryCommand.suggestion(exchange.question),
                   !model.memories.contains(where: { $0.text.caseInsensitiveCompare(fact) == .orderedSame })
                {
                    Button("＋ Remember this") { Task { await model.ask("remember that " + fact) } }
                        .buttonStyle(.plain).font(.system(.caption, design: .monospaced)).foregroundStyle(Self.cyan)
                        .padding(.leading, 60)
                }
                if !answer.eventIDs.isEmpty {
                    sourcesToggle(exchange.id, ids: answer.eventIDs)
                }
            } else if let failure = exchange.failure {
                line(assistant, failure, color: Self.amber)
            }
        }
    }

    private func line(_ who: String, _ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(who).font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(who == "YOU" ? .secondary : Self.cyan).frame(width: 52, alignment: .leading)
            Text(text).foregroundStyle(color).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    @ViewBuilder private func sourcesToggle(_ id: UUID, ids: [String]) -> some View {
        let open = openAnswers.contains(id)
        Button {
            if open {
                openAnswers.remove(id)
            } else {
                openAnswers.insert(id)
            }
        } label: {
            Text((open ? "▾ " : "▸ ") + (ids.count == 1 ? "1 source" : "\(ids.count) sources"))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.leading, 60)
        if open {
            ForEach(ids, id: \.self) { eventID in
                if let event = model.sources[eventID] {
                    SourceRow(event: event, accent: Self.cyan).padding(.leading, 60)
                }
            }
        }
    }
}

/// Sources that need attention, each with its one-click fix (#186). Shown only inside the open panel.
extension BriefView {
    func healthRow(_ line: SourceHealth.Line) -> some View {
        HStack(spacing: 8) {
            Text(BriefPresentation.health(line)).font(.system(.caption, design: .monospaced)).foregroundStyle(Self.amber)
            switch line.fix {
            case .openPrivacySettings:
                fixButton("Open Privacy settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .startMail:
                fixButton("Start Mail") {
                    guard let mail = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") else { return }
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = false
                    config.hides = true
                    NSWorkspace.shared.openApplication(at: mail, configuration: config)
                }
            case .none:
                EmptyView()
            }
        }
    }

    private func fixButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain).font(.system(.caption, design: .monospaced)).foregroundStyle(Self.cyan)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(Rectangle().strokeBorder(Self.cyan.opacity(0.5), lineWidth: 1))
    }
}
