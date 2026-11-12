import AegisKit
import Foundation

/// Aegis's jobs on the chosen brain (ADR-0038 stage 5). With Claude chosen and the panel open, questions that aren't
/// fixed commands or answered on the Mac, meeting prep and reply drafts go to Claude with Aegis's tools. If Claude
/// can't answer before any action ran, the local model answers and Aegis says so once; after an action it stops.
extension PanelModel {
    /// The run Claude's jobs share: one at a time.
    static var brainRunner = ClaudeCodeRunner()
    /// Each job's authority: a new job, a new question, Stop, closing the panel or a change of brain or switches
    /// moves it on, and a job whose number is old may no longer read, act or start.
    private(set) static var brainGeneration = 0
    /// What Claude has been told this conversation: only the owner's own words and Claude's own replies.
    private static var brainTurns: [(turn: ClaudeBrain.Turn, at: Date)] = []
    /// Said with the next local answer after Claude couldn't answer, once until Claude answers again.
    private(set) static var fallbackNote: String?
    private(set) static var saidFallback = false

    /// How a Claude job ended.
    enum BrainResult {
        case answered(Answer, spoken: String)
        /// Shown instead of an answer, with no local fallback: Stop, a refusal, or an action that already started.
        case stopped(String)
        /// Answer on this Mac instead; nothing ran.
        case fallback(String)
    }

    /// Ends the running Claude job's authority, and with `forget`, what Claude was told (its switches changed).
    static func revokeBrain(forget: Bool = false) {
        brainGeneration += 1
        if forget {
            brainTurns = []
        }
        let runner = brainRunner
        let older = brainGeneration
        Task { await runner.cancel(below: older) }
    }

    /// Forgets that the fallback was said: a fresh start, as at launch.
    static func resetFallback() {
        fallbackNote = nil
        saidFallback = false
    }

    /// A question's answer: a World or fixed command, else Claude when chosen, else the local model. Returns what was
    /// already spoken while Claude wrote.
    @discardableResult
    func requestAnswer(_ trimmed: String, id: UUID, speak: Bool = false) async -> String {
        if let world = await worldAnswer(trimmed) {
            guard isCurrentQuestion(id) else { return "" }
            askState = .answered(question: trimmed, answer: world)
            remember(Exchange(question: trimmed, answer: world, failure: nil))
            return ""
        }
        let claude = Self.claudeFor([]) && !ClaudeBrain.staysLocal(trimmed, now: Date(), calendar: .current)
        if claude, let spoken = await brainAnswer(trimmed, id: id, speak: speak) {
            return spoken
        }
        // With a Claude or OpenAI key saved, AegisCore may hand the question off (#223); never in place of Claude.
        let available = CloudKeys.availability
        let request: CoreRequest = available.providers.isEmpty || claude
            ? .ask(question: trimmed) : .converse(question: trimmed, cloud: available)
        let response = await service.handle(request)
        guard isCurrentQuestion(id) else { return "" }
        switch response {
        case let .handOff(approved):
            await handOff(approved, asked: trimmed, id: id)
        case let .answer(answer):
            let answer = Self.noted(answer)
            askState = .answered(question: trimmed, answer: answer)
            remember(Exchange(question: trimmed, answer: answer, failure: nil))
        case let .refused(code):
            fail(trimmed, BriefPresentation.askMessage(code))
        default:
            fail(trimmed, BriefPresentation.askMessage("bad_reply"))
        }
        return ""
    }

    /// Meeting prep (#184): recent contact with an event's attendees, shown in the conversation like an answer.
    func prep(_ row: TodayRow) async {
        guard let id = row.prepID else { return }
        let asked = "Prep for " + row.title
        let turn = beginQuestion(asked)
        defer { finishQuestion(turn) }
        if Self.claudeFor([.calendar]), let answer = await brainJob(ClaudeBrain.prep(title: row.title, time: row.time), id: turn) {
            guard isCurrentQuestion(turn) else { return }
            askState = .answered(question: asked, answer: answer)
            remember(Exchange(question: asked, answer: answer, failure: nil))
            return await finishAnswer(turn, spoken: false)
        }
        let response = await service.handle(.prep(occurrenceID: id))
        guard isCurrentQuestion(turn) else { return }
        switch response {
        case let .answer(answer):
            let answer = Self.noted(answer)
            askState = .answered(question: asked, answer: answer)
            remember(Exchange(question: asked, answer: answer, failure: nil))
            await finishAnswer(turn, spoken: false)
        case let .refused(code):
            fail(asked, BriefPresentation.askMessage(code))
        default:
            fail(asked, BriefPresentation.askMessage("bad_reply"))
        }
    }

    /// A reply draft from Claude, or nil to draft on this Mac. Only for someone in the owner's contacts whose open
    /// questions all come from sources left on: never a bare handle, nor a name only a switched-off source shows.
    func brainDraft(_ person: Brief.Person) async -> DraftState? {
        guard Self.claudeFor([.messages, .mail]), person.id.hasPrefix("contact:"), let name = ClaudeTools.safeName(person.name),
              let waiting = people.first(where: { $0.person.id == person.id }), !waiting.eventIDs.isEmpty
        else { return nil }
        let sources = await ClaudeReads(service: service).sources(of: waiting.eventIDs)
        guard waiting.eventIDs.allSatisfy({ sources[$0].map(ClaudeReads.enabled.contains) == true }) else { return nil }
        switch await runBrain(ClaudeBrain.draft(to: name), id: nil, acts: false, speak: false) {
        case let .answered(answer, _):
            return .ready(ReplyDraft(
                person: person,
                text: answer.text,
                eventIDs: answer.eventIDs,
                model: answer.model,
                generatedAt: Date()
            ))
        case let .stopped(message):
            return .failed(message)
        case .fallback:
            // The draft is made on this Mac; the notice waits for the next answer, where it's shown.
            return nil
        }
    }

    /// Claude's answer, shown and remembered, and what was spoken while it wrote; nil to answer on this Mac.
    private func brainAnswer(_ question: String, id: UUID, speak: Bool) async -> String? {
        Self.brainTurns.removeAll { Date().timeIntervalSince($0.at) > Chat.memory }
        let prompt = ClaudeBrain.prompt(question, history: Self.brainTurns.map(\.turn), now: Date(), timeZone: .current)
        let result = await runBrain(prompt, id: id, acts: true, speak: speak)
        guard isCurrentQuestion(id) else { return "" }
        switch result {
        case let .answered(answer, spoken):
            let turn = (turn: ClaudeBrain.Turn(owner: question, reply: answer.text), at: Date())
            Self.brainTurns = Array((Self.brainTurns + [turn]).suffix(ClaudeBrain.maxTurns))
            askState = .answered(question: question, answer: answer)
            remember(Exchange(question: question, answer: answer, failure: nil))
            return spoken
        case let .stopped(message):
            let answer = Self.said(message)
            askState = .answered(question: question, answer: answer)
            remember(Exchange(question: question, answer: answer, failure: nil))
            return ""
        case let .fallback(note):
            Self.note(note)
            return nil
        }
    }

    /// Prep's answer from Claude, or nil to answer on this Mac.
    private func brainJob(_ prompt: String, id: UUID) async -> Answer? {
        switch await runBrain(prompt, id: id, acts: false, speak: false) {
        case let .answered(answer, _): return answer
        case let .stopped(message): return Self.said(message)
        case let .fallback(note):
            Self.note(note)
            return nil
        }
    }

    /// One Claude job: the reply typed on screen as it comes (and spoken, sentence by sentence, when `speak`), with
    /// Aegis's read tools under the owner's switches, and its action tools when `acts`. It holds the owner's
    /// authority only while it's the newest job and Claude is still chosen with the panel open.
    func runBrain(_ prompt: String, id: UUID?, acts: Bool, speak: Bool) async -> BrainResult {
        Self.revokeBrain()
        let generation = Self.brainGeneration
        let live: @Sendable @MainActor () -> Bool = { generation == PanelModel.brainGeneration && PanelModel.claudeFor([]) }
        let runner = Self.brainRunner
        let (pieces, sink) = AsyncStream.makeStream(of: String.self)
        let shown = Task { @MainActor [weak self] in
            var text = ""
            var said = ""
            for await piece in pieces {
                text += piece
                guard let self, let id, live(), isCurrentQuestion(id) else { continue }
                partialAnswer = text
                let done = Self.sentences(text)
                guard speak, done.count > said.count else { continue }
                if said.isEmpty {
                    voice.beginStreaming()
                }
                voice.continueStreaming(String(done.dropFirst(said.count)).trimmingCharacters(in: .whitespacesAndNewlines))
                said = done
            }
            return said
        }
        let reads = ClaudeCodeRunner.Reads(
            source: ClaudeBrainTools(model: self, reads: ClaudeReads(service: service), live: live), enabled: ClaudeReads.enabled,
            acts: acts
        )
        let system = ClaudeBrain.system(name: personality.name, style: personality.style.title)
        var report = ClaudeCodeRunner.Report(ending: .busy)
        // The last job takes a moment to end after it's stopped; this one starts only while it still has authority.
        for _ in 0 ..< 25 where report.ending == .busy && live() {
            report = await runner.report(
                system: system, prompt: prompt, choice: ClaudeCodeRunner.choice, timeout: 180, reads: reads, token: generation
            ) { sink.yield($0) }
            if report.ending == .busy {
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        sink.finish()
        let spoken = await shown.value
        if live() {
            partialAnswer = ""
        }
        switch report.ending {
        case let .outcome(.answer(text, model)):
            Self.saidFallback = false
            let answer = Answer(
                text: text,
                eventIDs: report.readIDs,
                scheduleIDs: [],
                model: model.isEmpty ? "claude" : model,
                generatedAt: Date()
            )
            return .answered(answer, spoken: spoken)
        case .outcome(.declined):
            return .stopped("Claude declined to answer that.")
        case .cancelled:
            return .stopped("Stopped.")
        case .busy where !live():
            return .stopped("Stopped.")
        default:
            // Never replayed once an action started: the local model might do it again.
            if report.actions > 0 {
                return .stopped("Claude stopped partway, after starting an action. Check what it did before asking again.")
            }
            return .fallback(Self.fallbackReason(report.ending))
        }
    }

    /// Claude is the brain, the panel is open, and (for a job that needs them) one of `sources` is switched on.
    static func claudeFor(_ sources: Set<ClaudeTools.Category>) -> Bool {
        Brain.current == .claude && HUDPresence.shared.open && (sources.isEmpty || !sources.isDisjoint(with: ClaudeReads.enabled))
    }

    private static func note(_ reason: String) {
        fallbackNote = saidFallback ? nil : reason
        saidFallback = true
    }

    /// The local answer, with the fallback's note in front the first time.
    private static func noted(_ answer: Answer) -> Answer {
        guard let note = fallbackNote else { return answer }
        fallbackNote = nil
        return Answer(
            text: note + " " + answer.text, eventIDs: answer.eventIDs, scheduleIDs: answer.scheduleIDs, model: answer.model,
            generatedAt: answer.generatedAt
        )
    }

    private static func fallbackReason(_ ending: ClaudeCodeRunner.Ending) -> String {
        switch ending {
        case .outcome(.signedOut):
            return "Claude Code isn't signed in, so I answered on this Mac."
        case let .outcome(.limit(resets)):
            let until = resets.map { " until " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
            return "Your Claude plan's limit is used up\(until), so I answered on this Mac."
        default:
            return "I couldn't reach Claude, so I answered on this Mac."
        }
    }

    /// The text up to its last finished sentence, leading space dropped, for speaking as Claude writes.
    static func sentences(_ text: String) -> String {
        let text = String(text.drop { $0.isWhitespace })
        var end: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?".contains(text[index]), next == text.endIndex || text[next].isWhitespace {
                end = next
            }
            index = next
        }
        return end.map { String(text[..<$0]) } ?? ""
    }
}
