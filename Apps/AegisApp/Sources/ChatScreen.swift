import AegisKit
import AppKit
import SwiftUI

/// 04 CHAT, a terminal for talking to Aegis (#163, #198): the conversation with what Aegis read or did under its
/// answers, the command line with the mic, and on the right the reactor, what the last answer drew on and the voice.
struct ChatScreen: View {
    let model: PanelModel
    @Binding var screen: HUDScreen
    @State private var question = ""
    @State private var openAnswers: Set<UUID> = []
    @State private var opened = Date()
    @FocusState private var typing: Bool

    /// Where a line's text starts: the prompt column and its gap.
    private static let textInset = 64 + HUD.space3

    var body: some View {
        HUDShell {
            HUDTopBar(model: model, screen: $screen)
        } content: {
            HStack(alignment: .top, spacing: HUD.space8) {
                terminal.frame(maxWidth: .infinity, maxHeight: .infinity)
                side.frame(width: 260)
            }
        }
        .onAppear { typing = true }
        .onChange(of: model.voice.state) { _, state in
            if case let .listening(words) = state {
                question = words
            }
        }
    }

    private var name: String {
        model.personality.name.lowercased()
    }

    // MARK: The terminal

    private var terminal: some View {
        VStack(alignment: .leading, spacing: HUD.space2) {
            HUDAsciiDivider(label: "Session · " + (model.handingOff.map { "via " + $0.name } ?? "local"), width: 96, tone: HUD.primary)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("[" + opened.formatted(date: .omitted, time: .standard) + "] chat opened · model "
                            + (model.stored?.brief.model ?? "local") + " · \(model.memories.count) memories")
                            .hudType(.caption).foregroundStyle(HUD.inkMuted).padding(.bottom, HUD.space2)
                        ForEach(Array(model.thread.enumerated()), id: \.element.id) { index, exchange in
                            exchangeView(exchange, index: index)
                        }
                        if case let .asking(asked) = model.askState {
                            HUDChatLine(who: "you", text: asked)
                            HUDChatLine(
                                who: name, text: model.handingOff.map { "asking \($0.name)…" } ?? model.partialAnswer, aegis: true,
                                writing: true
                            )
                        }
                        taskControls
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: model.thread.count) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: model.askState) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(maxHeight: .infinity)
            input
            proposal
            HStack(spacing: HUD.space2) {
                ForEach(["what do you remember", "what's my morning routine", "list my skills"], id: \.self) { phrase in
                    HUDCommandChip(phrase: phrase) { Task { await model.submit(phrase) } }
                }
            }
        }
    }

    /// One question and its answer; arriving, each line rises into place 45 ms after the one before.
    private func exchangeView(_ exchange: PanelModel.Exchange, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDChatLine(who: "you", text: exchange.question).hudArrive(.rise, after: HUDMotion.stagger(2 * index, 0.045))
            Group {
                if let answer = exchange.answer {
                    HUDChatLine(who: name, text: answer.text, aegis: true) {
                        let meta = Self.meta(answer)
                        if !meta.isEmpty {
                            Text(meta).hudType(.caption).foregroundStyle(HUD.inkMuted)
                        }
                        answerActions(exchange, answer: answer)
                    }
                } else if let failure = exchange.failure {
                    HUDChatLine(who: name, text: failure, aegis: true, failed: true)
                }
            }
            .hudArrive(.rise, after: HUDMotion.stagger(2 * index + 1, 0.045))
        }
    }

    /// What Aegis read or which model answered, in mono under its turn.
    private static func meta(_ answer: Answer) -> String {
        var parts: [String] = []
        if !answer.eventIDs.isEmpty {
            parts.append(answer.eventIDs.count == 1 ? "read 1 message" : "read \(answer.eventIDs.count) messages")
        }
        if !answer.scheduleIDs.isEmpty {
            parts.append(answer.scheduleIDs.count == 1 ? "1 calendar item" : "\(answer.scheduleIDs.count) calendar items")
        }
        if PanelModel.isHandOff(answer), let model = answer.model {
            parts
                .append("via " + (model.hasPrefix("claude") ? "Claude" : "ChatGPT") + " · " +
                    (model.hasSuffix("-plan") ? "your plan" : model))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func answerActions(_ exchange: PanelModel.Exchange, answer: Answer) -> some View {
        let fact = answer.model == "memory" ? nil : MemoryCommand.suggestion(exchange.question)
        let rememberable = fact.map { fact in !model.memories.contains { $0.text.caseInsensitiveCompare(fact) == .orderedSame } } ?? false
        if exchange.folder != nil || rememberable || !answer.eventIDs.isEmpty {
            HStack(spacing: HUD.space2) {
                if let folder = exchange.folder {
                    Button("Open the task's folder") { NSWorkspace.shared.open(folder) }
                }
                // Something the owner said about themselves can be remembered with one click (#222).
                if rememberable, let fact {
                    Button("Remember this") { Task { await model.ask("remember that " + fact) } }
                }
                if !answer.eventIDs.isEmpty {
                    Button((openAnswers.contains(exchange.id) ? "Hide" : "Show") + " sources") {
                        if openAnswers.contains(exchange.id) {
                            openAnswers.remove(exchange.id)
                        } else {
                            openAnswers.insert(exchange.id)
                        }
                    }
                }
            }
            .buttonStyle(HUDChipStyle(muted: true))
            .padding(.top, HUD.space1)
            if openAnswers.contains(exchange.id) {
                ForEach(answer.eventIDs, id: \.self) { eventID in
                    if let event = model.sources[eventID] {
                        SourceRow(event: event, accent: HUD.primary)
                    }
                }
            }
        }
    }

    /// A task for Claude or ChatGPT (#235) or an action awaiting the owner (#276): confirm or cancel, then a running
    /// timer with Stop.
    @ViewBuilder private var taskControls: some View {
        if ActionPresence.shared.pending != nil {
            HStack(spacing: HUD.space4) {
                Button(ActionPresence.shared.pending?.button ?? "Add") { Task { await model.confirmAction() } }
                    .buttonStyle(HUDPlateStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { Task { await model.cancelAction() } }.buttonStyle(HUDPlateStyle())
            }
            .padding(.leading, Self.textInset)
            .padding(.vertical, HUD.space2)
        }
        if model.pendingTask != nil {
            HStack(spacing: HUD.space4) {
                Button("Start") { Task { await model.startTask() } }
                    .buttonStyle(HUDPlateStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { Task { await model.cancelTask() } }.buttonStyle(HUDPlateStyle())
            }
            .padding(.leading, Self.textInset)
            .padding(.vertical, HUD.space2)
        }
        if let running = model.runningTask, let started = running.started {
            HStack(spacing: HUD.space3) {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(started))
                    Text("\(running.request.provider.name) is working on it… \(seconds / 60):" + String(format: "%02d", seconds % 60))
                        .hudType(.data).foregroundStyle(HUD.primary)
                }
                Button("Stop") { Task { await model.stopTask() } }.buttonStyle(HUDChipStyle(muted: true))
            }
            .padding(.leading, Self.textInset)
        }
    }
}

extension ChatScreen {
    // MARK: The command line

    /// Ask Aegis anything: Return sends; answers come only from the owner's own data on the Mac.
    private var input: some View {
        HStack(spacing: HUD.space2) {
            Text(name + " ~ %").hudType(.term).foregroundStyle(HUD.primary)
            TextField(
                "Ask", text: $question,
                prompt: Text("ask \(model.personality.name) anything, or tell it what to remember").foregroundStyle(HUD.inkMuted)
            )
            .textFieldStyle(.plain).hudType(.term).focused($typing)
            .onSubmit {
                let asked = question
                question = ""
                Task { await model.submit(asked) }
            }
            if case .asking = model.askState {
                HUDTag(word: "Thinking", tone: HUD.primary)
            }
            Text("⏎ send").hudType(.caption).foregroundStyle(HUD.inkMuted)
                .padding(.leading, HUD.space2)
                .overlay(alignment: .leading) { Rectangle().fill(HUD.line).frame(width: 1) }
            micButton
        }
        .hudField(focused: typing)
    }

    /// Ask by voice (#178): click, speak, pause; click again to stop early. On-device only.
    private var micButton: some View {
        Button(model.voice.isListening ? "Listening" : "Mic") {
            if model.voice.isListening {
                model.voice.stop()
            } else {
                Task {
                    await model.voice.listen { words in
                        question = ""
                        Task { await model.submit(words, spoken: true) }
                    }
                }
            }
        }
        .buttonStyle(HUDChipStyle(live: model.voice.isListening))
        .help("Ask by voice. Recognised on this Mac; nothing is recorded.")
    }

    /// Plain-language rules (#179): what the owner asked for, one click to apply; and why the voice can't listen.
    @ViewBuilder private var proposal: some View {
        if let rule = model.proposal {
            HStack(spacing: HUD.space2) {
                Text(rule.question)
                Spacer(minLength: HUD.space2)
                Button(Self.verb(rule.action)) { Task { await model.apply(rule) } }.buttonStyle(HUDChipStyle())
                Button("Cancel") { model.dismissProposal() }.buttonStyle(HUDChipStyle(muted: true))
            }
            .padding(HUD.space2)
            .overlay(Rectangle().strokeBorder(HUD.line, lineWidth: HUD.strokeHair))
        } else if let text = model.proposalNotice {
            notice(text) { model.dismissProposal() }
        }
        if case let .unavailable(reason) = model.voice.state {
            notice(reason) { model.voice.dismissNotice() }
        }
    }

    private func notice(_ text: String, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: HUD.space2) {
            Text(text).hudType(.caption).foregroundStyle(HUD.warn)
            Button("✕", action: dismiss).buttonStyle(.plain).foregroundStyle(HUD.inkMuted).accessibilityLabel("Dismiss")
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

    // MARK: The core, its context and the voice

    private var side: some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDCore(model: model, size: 220, label: model.personality.name).frame(maxWidth: .infinity).padding(.bottom, HUD.space4)
            HUDSection(title: "Using", code: "CONTEXT", linked: false) {
                let answer = model.thread.last?.answer
                let events = (answer?.eventIDs ?? []).compactMap { model.sources[$0] }
                VStack(alignment: .leading, spacing: 0) {
                    if events.isEmpty {
                        context("----", "nothing yet")
                    }
                    ForEach(events.prefix(6), id: \.id) { event in
                        context(
                            event.source == .email ? "mail" : event.source == .notification ? "note" : "msg",
                            SourcePresentation.heading(event)
                        )
                    }
                    if let answer, PanelModel.isHandOff(answer), let model = answer.model {
                        context("via", model)
                    }
                }
            }
            HUDSection(title: "Voice", code: "MIC", linked: false, index: 1) {
                let active = model.voice.isListening || model.voice.speaking
                HUDAsciiArt(shape: .wave, cols: 30, rows: 6, tone: active ? HUD.primary : HUD.accent, animate: active)
                    .frame(maxWidth: .infinity)
                HStack {
                    Text("Output").hudType(.label).foregroundStyle(HUD.inkMuted)
                    Spacer()
                    Text(model.voice.isListening ? "listening" : model.voice.speaking ? "speaking" : "idle")
                        .hudType(.data).foregroundStyle(active ? HUD.primary : HUD.ink)
                }
            }
        }
    }

    private func context(_ kind: String, _ text: String) -> some View {
        (Text(kind + " ").foregroundStyle(HUD.accent) + Text(text))
            .hudType(.data)
            .lineLimit(1)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { HUDRule() }
    }
}

extension HUDShell where Bottom == EmptyView {
    init(wires: Bool = false, @ViewBuilder top: () -> Top, @ViewBuilder content: () -> Content) {
        self.init(wires: wires, top: top, content: content, bottom: { EmptyView() })
    }
}
