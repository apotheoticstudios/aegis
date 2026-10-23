import AegisKit
import Foundation
import Observation
import OSLog

/// What the panel shows, loaded from AegisCore's `CoreService`.
@MainActor
@Observable
final class PanelModel {
    enum Phase: Equatable {
        case loading, ready
        case unavailable(String)

        /// The menu bar symbol for each state.
        var symbol: String {
            switch self {
            case .loading: "circle.dotted"
            case .ready: "hexagon"
            case .unavailable: "exclamationmark.triangle"
            }
        }
    }

    private(set) var phase: Phase = .loading
    private(set) var stored: StoredBrief?
    /// True while a brief the user asked for is being written.
    private(set) var writing = false
    /// A short note about the last request (e.g. why no new brief is coming); the brief stays on screen.
    private(set) var notice: String?

    /// The menu bar glows (a filled hexagon) when a brief with urgent items arrived since the panel was
    /// last opened (#169). Silent: no sound, no pop-up; off with "Glow for urgent items".
    private(set) var glow = false
    /// When the owner last opened the panel (kept across launches).
    private(set) var lastSeen: Date = UserDefaults.aegis.object(forKey: "lastSeenBrief") as? Date ?? .distantPast
    var glowEnabled: Bool = UserDefaults.aegis.object(forKey: "glowForUrgent") as? Bool ?? true {
        didSet {
            UserDefaults.aegis.set(glowEnabled, forKey: "glowForUrgent")
            updateGlow()
        }
    }

    /// Every few minutes while the panel is closed: picks up a new brief so the glow (and the panel) is current.
    func checkForNewBrief() async {
        if case let .brief(brief?) = await service.handle(.latestBrief), brief.storedAt != stored?.storedAt {
            if brief.inputRevision != stored?.inputRevision {
                sources = [:]
                loadedSources = []
            }
            stored = brief
            phase = .ready
        }
        updateGlow()
    }

    private func updateGlow() {
        guard glowEnabled, let stored else {
            glow = false
            return
        }
        glow = stored.storedAt > lastSeen && stored.brief.items.contains { $0.priority == .urgent }
    }

    private func markSeen(_ now: Date) {
        lastSeen = now
        UserDefaults.aegis.set(now, forKey: "lastSeenBrief")
        glow = false
    }

    /// When the panel opens: shows the stored brief and, on a real install, writes a fresh one in the
    /// background if it's more than an hour old (owner: "when I want it").
    func opened(now: Date = Date()) async {
        markSeen(now)
        // Prepare the bundled voice only in the real panel, never in the synthetic test host.
        voice.prepare(enabled: !isSample)
        // The model too (#209): loaded while the owner reads or starts to ask.
        _ = await service.handle(.prepareModel)
        await refresh()
        guard !isSample, !writing else {
            return
        }
        let age = stored.map { now.timeIntervalSince($0.storedAt) } ?? .infinity
        if age > 3600 {
            await writeNow()
        }
    }

    /// The day the schedule section shows: today, or tomorrow after 5 pm (#172).
    private(set) var scheduleDay = Calendar.current.startOfDay(for: Date())

    /// Today's calendar occurrences and reminders, straight from AegisCore's store.
    private(set) var todayOccurrences: [CalendarOccurrence] = []
    private(set) var todayReminders: [ReminderItem] = []
    /// The events items cite, fetched when an item is opened; cleared when a different brief arrives.
    private(set) var sources: [String: Event] = [:]
    /// Items whose sources were asked for and came back (some may be gone from the store).
    private(set) var loadedSources: Set<[String]> = []

    /// Fetches the events an item cites from AegisCore, the first time the item is opened.
    func loadSources(for item: Brief.Item) async {
        await loadSources(ids: item.eventIDs)
    }

    /// Fetches cited events (an item's or an answer's) the first time they're shown, as many requests as AegisCore's
    /// limit needs. The list counts as loaded only once every request answered, so showing it again retries a failure.
    func loadSources(ids: [String]) async {
        guard !loadedSources.contains(ids) else { return }
        let missing = ids.filter { sources[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: CoreRequest.maxSourceIDs) {
            let batch = missing[start ..< min(start + CoreRequest.maxSourceIDs, missing.count)]
            guard case let .events(events) = await service.handle(.sources(ids: Array(batch))) else { return }
            for event in events {
                sources[event.id] = event
            }
        }
        loadedSources.insert(ids)
    }

    /// Ask Aegis anything (#163): what the question box shows.
    enum AskState: Equatable {
        case idle
        case asking(String)
        case answered(question: String, answer: Answer)
        case failed(question: String, message: String)
    }

    var askState: AskState = .idle
    @ObservationIgnored private var questionID: UUID?

    /// Resumes hands-free capture as soon as the current reply is ready, even without playback.
    @ObservationIgnored var questionFinished: () -> Void = {}
    /// Claude or ChatGPT while a hand-off is under way (#223).
    private(set) var handingOff: CloudHandOff.Provider?
    @ObservationIgnored let cloud = CloudClient()
    @ObservationIgnored let plan = PlanRunner()
    @ObservationIgnored let actions: ActionLog?
    /// The reply as it's written, before it's finished (#263).
    var partialAnswer = ""
    /// Aegis's name and personality (#241).
    private(set) var personality = Personality.standard
    /// A task waiting for Start, and the one running (#235).
    private(set) var pendingTask: PlanTask?
    private(set) var runningTask: PlanTask?
    @ObservationIgnored private var taskWork: Task<Result<String, HandOffProblem>, Never>?
    @ObservationIgnored private var taskViaPlan = false

    /// One question and Aegis's reply in the conversation view (#198).
    /// The latest twenty visible exchanges, oldest first; cleared only at the owner's request.
    private(set) var thread: [Exchange] = []

    /// Who is waiting on the owner (#165), longest first; refreshed with the brief.
    private(set) var people: [PersonWaiting] = []
    /// Sources that need attention (#186): a changed format, a missing permission or app, or no recent scan.
    private(set) var health: [SourceHealth.Line] = []

    /// Promises in the owner's own messages that still look open (#182): overdue first.
    private(set) var commitments: [Commitment] = []
    /// What got done today (#211): answers, kept promises, completed reminders and held meetings, newest first.
    private(set) var done: [DoneItem] = []
    /// What the owner asked Aegis to remember (#222), newest first.
    private(set) var memories: [MemoryNote] = []
    /// What Aegis treated as junk in the last day (#167), most filtered first.
    private(set) var filtered: [FilteredSender] = []

    /// A reply draft for someone waiting (#176): being written, ready to copy, or why there's none.
    enum DraftState: Equatable {
        case drafting
        case ready(ReplyDraft)
        case failed(String)
    }

    /// Reply drafts by person ID; Aegis never sends them, the owner copies one.
    private(set) var drafts: [String: DraftState] = [:]

    /// Asks the local model for a reply to this person's open questions (about 10 to 30 seconds).
    func draftReply(_ person: Brief.Person) async {
        guard drafts[person.id] != .drafting else { return }
        drafts[person.id] = .drafting
        switch await service.handle(.draftReply(personID: person.id)) {
        case let .draft(draft):
            drafts[person.id] = .ready(draft)
        case let .refused(code):
            drafts[person.id] = .failed(BriefPresentation.draftMessage(code))
        default:
            drafts[person.id] = .failed(BriefPresentation.draftMessage("unexpected"))
        }
    }

    /// Talking to Aegis while the panel is open (#178).
    let voice = Voice()

    /// The owner's rules (#175): junk and trusted senders, muted people and group chats.
    private(set) var rules: OwnerRules = .empty

    /// "Not junk": AegisCore trusts this sender from now on and returns the updated list.
    func trust(_ sender: FilteredSender) async {
        if case let .filtered(list) = await service.handle(.trustSender(handle: sender.handle)) {
            filtered = list
            await reloadRules()
        }
    }

    /// "Junk" on a source (#175): this sender's messages are junk from now on; the brief drops them at once.
    func markJunk(_ event: Event) async {
        guard let handle = BriefPresentation.junkHandle(event) else { return }
        await markJunk(handle: handle)
    }

    func markJunk(handle: String) async {
        guard case let .filtered(list) = await service.handle(.markJunk(handle: handle)) else { return }
        filtered = list
        await reloadRules()
        await reloadBrief()
    }

    /// A rule the owner typed or said in the Ask bar (#179), waiting for their click; never applied on its own.
    private(set) var proposal: RuleProposal?
    /// Why a typed rule found nobody, or more than one.
    private(set) var proposalNotice: String?

    /// The Ask bar: a plain-language rule ("mute the family group") becomes a proposal; anything else is asked.
    /// Steps of a spoken question, as codes only (#204).
    @ObservationIgnored private let voiceLog = Logger(subsystem: "dev.aegis.app", category: "voice")

    func submit(_ text: String, spoken: Bool = false) async {
        voiceLog.notice("submit: spoken \(spoken), words \(text.split(separator: " ").count)")
        proposal = nil
        proposalNotice = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = beginQuestion(trimmed)
        defer { finishQuestion(id) }
        let interpreted = await service.handle(.interpret(text: trimmed))
        guard isCurrentQuestion(id) else { return }
        switch interpreted {
        case let .proposal(found):
            askState = .idle
            proposal = found
            remember(Exchange(question: trimmed, answer: Self.said(found.question), failure: nil))
            if spoken {
                voice.speak(found.question)
            }
        case .refused(code: "no_match"):
            askState = .idle
            proposalNotice = "I couldn't find who you meant. Try the name as it shows in the brief."
            remember(Exchange(question: trimmed, answer: nil, failure: proposalNotice))
        case .refused(code: "ambiguous"):
            askState = .idle
            proposalNotice = "That matches more than one person or chat. Try the full name."
            remember(Exchange(question: trimmed, answer: nil, failure: proposalNotice))
        default:
            await requestAnswer(trimmed, id: id)
            await finishAnswer(id, spoken: spoken)
        }
    }

    /// "Mute" on a person or group chat (#175): out of the brief, People waiting and the glow.
    func mute(_ person: Brief.Person) async {
        if case let .rules(updated) = await service.handle(.mute(personID: person.id, name: person.name)) {
            rules = updated
            await reloadBrief()
        }
    }

    func unmute(_ id: String) async {
        if case let .rules(updated) = await service.handle(.unmute(personID: id)) {
            rules = updated
            await reloadBrief()
        }
    }

    private func reloadRules() async {
        if case let .rules(current) = await service.handle(.rules) {
            rules = current
        }
    }

    /// The stored brief again after a rule changed (AegisCore leaves out what the rules hide), and who's waiting.
    private func reloadBrief() async {
        if case let .brief(brief?) = await service.handle(.latestBrief) {
            stored = brief
        }
        if case let .people(waiting) = await service.handle(.people) {
            people = waiting
        }
        updateGlow()
    }

    /// Meeting prep (#184): recent contact with an event's attendees, shown in the conversation like an answer.
    func prep(_ row: TodayRow) async {
        guard let id = row.prepID else { return }
        let asked = "Prep for " + row.title
        let turn = beginQuestion(asked)
        defer { finishQuestion(turn) }
        let response = await service.handle(.prep(occurrenceID: id))
        guard isCurrentQuestion(turn) else { return }
        switch response {
        case let .answer(answer):
            askState = .answered(question: asked, answer: answer)
            remember(Exchange(question: asked, answer: answer, failure: nil))
            await finishAnswer(turn, spoken: false)
        case let .refused(code):
            fail(asked, BriefPresentation.askMessage(code))
        default:
            fail(asked, BriefPresentation.askMessage("bad_reply"))
        }
    }

    private func fail(_ question: String, _ message: String) {
        askState = .failed(question: question, message: message)
        remember(Exchange(question: question, answer: nil, failure: message))
    }

    func remember(_ exchange: Exchange) {
        thread = Array((thread + [exchange]).suffix(20))
    }

    /// Back to the brief.
    func clearAnswer() {
        questionID = nil
        handingOff = nil
        voice.stopSpeaking()
        askState = .idle
    }

    let isSample: Bool
    let service: any CoreService

    init(service: any CoreService, actions: ActionLog? = PanelModel.actionLog()) {
        self.service = DiagnosticCoreService(base: service)
        self.actions = actions
        isSample = service is SampleCoreService
    }

    /// Asks AegisCore to write a new brief now, then follows it until it's stored (about a minute with
    /// the 4B model) or AegisCore stops generating. The last brief stays on screen meanwhile.
    func writeNow() async {
        let before = stored?.storedAt
        notice = nil
        switch await service.handle(.refreshBrief(reason: .user)) {
        case .accepted:
            writing = true
        case let .refused(code):
            // Keep showing the last brief; a note says why no new one is coming.
            writing = false
            notice = code == "already_generating" ? "A brief is already being written." : "Aegis Core said no (\(code))."
            if stored == nil {
                phase = .unavailable(notice ?? "")
            }
            return
        default:
            notice = "Aegis Core didn't answer."
            if stored == nil {
                phase = .unavailable(notice ?? "")
            }
            return
        }
        for _ in 0 ..< 120 {
            try? await Task.sleep(for: .seconds(5))
            await refresh()
            if stored?.storedAt != before {
                break
            }
            guard case let .status(status) = await service.handle(.status), status.generating else {
                break
            }
        }
        writing = false
    }

    func refresh() async {
        if case let .status(status) = await service.handle(.status) {
            health = SourceHealth.lines(status.sources, now: Date()).filter { $0.state != .healthy }
        }
        if case let .people(waiting) = await service.handle(.people) {
            people = waiting
        }
        if case let .commitments(list) = await service.handle(.commitments) {
            commitments = list
        }
        if case let .done(list) = await service.handle(.done) {
            done = list
        }
        await reloadMemories()
        await refreshRoutine()
        await loadPersonality()
        Task { await refreshWorldBrief() }
        if case let .filtered(list) = await service.handle(.filtered) {
            filtered = list
        }
        await reloadRules()
        let start = BriefPresentation.scheduleDay(now: Date(), calendar: .current)
        scheduleDay = start
        if case let .schedule(occurrences, reminders) = await service.handle(.schedule(from: start, to: start.addingTimeInterval(86400))) {
            todayOccurrences = occurrences
            todayReminders = reminders
        }
        switch await service.handle(.latestBrief) {
        case let .brief(brief?):
            if brief.inputRevision != stored?.inputRevision {
                sources = [:]
                loadedSources = []
            }
            stored = brief
            phase = .ready
        case .brief(nil):
            stored = nil
            phase = .unavailable("No brief yet. The first one is written before your opening time.")
        default:
            phase = .unavailable("Aegis Core didn't answer.")
        }
    }
}

/// One line of the TODAY section: a time (or ALL DAY, DUE, OVERDUE), a title and an optional place.
/// Applying a plain-language rule (#179, #185), apart from the main body.
extension PanelModel {
    /// Ends the spoken conversation at the owner's request, without dismissing unfinished work; CHAT keeps its transcript.
    func endVoiceConversation() {
        guard pendingTask == nil, runningTask == nil else { return }
        clearAnswer()
    }

    /// The owner clicked the proposal's button.
    func apply(_ rule: RuleProposal) async {
        proposal = nil
        switch rule.action {
        case .mute:
            await mute(Brief.Person(id: rule.target, name: rule.name))
        case .unmute:
            await unmute(rule.target)
        case .vip, .unvip, .keywordUrgent, .keywordHide, .removeKeyword:
            await applyPriorityRule(rule)
        case .junk:
            await markJunk(handle: rule.target)
        case .notJunk:
            if case let .filtered(list) = await service.handle(.trustSender(handle: rule.target)) {
                filtered = list
                await reloadRules()
                await reloadBrief()
            }
        }
    }

    private func applyPriorityRule(_ rule: RuleProposal) async {
        let request: CoreRequest
        switch rule.action {
        case .vip: request = .vip(personID: rule.target, name: rule.name)
        case .unvip: request = .unvip(personID: rule.target)
        case .keywordUrgent: request = .addKeyword(phrase: rule.target, effect: .urgent)
        case .keywordHide: request = .addKeyword(phrase: rule.target, effect: .hide)
        case .removeKeyword: request = .removeKeyword(phrase: rule.target)
        default: return
        }
        if case .rules = await service.handle(request) {
            await reloadRules()
            await reloadBrief()
        }
    }

    func dismissProposal() {
        proposal = nil
        proposalNotice = nil
    }
}

struct TodayRow: Equatable {
    enum Kind: Equatable {
        case allDay, timed, reminder, overdue
    }

    let kind: Kind
    let time: String
    let title: String
    let detail: String?
    /// A calendar event with other people invited can be prepped (#184): its occurrence ID.
    var prepID: String?
}

/// How a brief reads in the panel. Pure and unit-tested.
enum BriefPresentation {
    /// Today's schedule: all-day events, then timed events by start (cancelled ones left out), then
    /// reminders that are overdue or due today. Times are local.
    static func today(
        occurrences: [CalendarOccurrence], reminders: [ReminderItem], now: Date, calendar: Calendar
    ) -> [TodayRow] {
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = dayStart.addingTimeInterval(86400)
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "HH:mm"
        let events = occurrences.filter { $0.status != .cancelled && $0.start < dayEnd && $0.end > dayStart }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
            .map { occurrence in
                TodayRow(
                    kind: occurrence.isAllDay ? .allDay : .timed,
                    time: occurrence.isAllDay ? "ALL DAY" : format.string(from: occurrence.start) + "–" + format
                        .string(from: occurrence.end),
                    title: occurrence.title.isEmpty ? "(no title)" : occurrence.title,
                    detail: occurrence.location,
                    prepID: occurrence.attendees?.contains { !$0.isOwner } == true ? occurrence.id : nil
                )
            }
        let due = reminders.filter { !$0.isCompleted && ($0.due.map { $0.date < dayEnd } ?? false) }
            .sorted { ($0.due?.date ?? dayEnd) < ($1.due?.date ?? dayEnd) }
            .map { reminder -> TodayRow in
                let date = reminder.due?.date ?? dayStart
                let overdue = date < dayStart
                let time = overdue ? "OVERDUE" : (reminder.due?.hasTime == true ? format.string(from: date) : "DUE")
                return TodayRow(kind: overdue ? .overdue : .reminder, time: time, title: reminder.title, detail: nil)
            }
        return events + due
    }

    /// One line of a section: an item, or one person's items folded under their name (#158).
    enum Entry: Equatable {
        case item(Brief.Item)
        case person(Brief.Person, [Brief.Item])

        /// The most urgent of its items.
        var priority: Brief.Priority {
            switch self {
            case let .item(item): item.priority
            case let .person(_, items): Brief.Priority.allCases.first { level in items.contains { $0.priority == level } } ?? .fyi
            }
        }
    }

    struct Section: Equatable {
        let priority: Brief.Priority
        let entries: [Entry]
    }

    /// Urgent first, then replies, then the rest; empty groups left out; the model's order kept inside each.
    /// A person with two or more items gets one entry, in the section of their most urgent item.
    static func sections(_ brief: Brief) -> [Section] {
        var counts: [String: Int] = [:]
        for id in brief.items.compactMap(\.person?.id) {
            counts[id, default: 0] += 1
        }
        var entries: [Entry] = [], placed: Set<String> = []
        for item in brief.items {
            guard let person = item.person, counts[person.id, default: 0] > 1 else {
                entries.append(.item(item))
                continue
            }
            guard placed.insert(person.id).inserted else { continue }
            entries.append(.person(person, brief.items.filter { $0.person?.id == person.id }))
        }
        return Brief.Priority.allCases.compactMap { priority in
            let inSection = entries.filter { $0.priority == priority }
            return inSection.isEmpty ? nil : Section(priority: priority, entries: inSection)
        }
    }

    /// Why a sender was filtered, in a word or two.
    static func reason(_ reason: FilterReason) -> String {
        switch reason {
        case .bulk: "Bulk mail"
        case .code: "Code"
        case .promotion: "Promotion"
        case .appNotice: "App notice"
        case .delivery: "Delivery"
        case .automated: "Automated"
        case .markedJunk: "Marked junk"
        }
    }

    /// "FILTERED · 12 hidden · 2 muted"
    static func filteredHeading(hidden: Int, muted: Int) -> String {
        "FILTERED · \(hidden) hidden" + (muted > 0 ? " · \(muted) muted" : "")
    }

    /// What "Junk" marks for a source: an incoming sender who isn't a contact (their handle, or the app for a
    /// notification); nil for the owner's own messages and for contacts (Mute is for people).
    static func junkHandle(_ event: Event) -> String? {
        // A number on several contact cards is a contact (#218): Junk is for strangers' senders.
        guard !SenderDisplay.isOutgoing(event), event.senderContact == nil, !event.flags.contains(.ambiguousSender) else {
            return nil
        }
        if event.source == .notification {
            // Junking Messages itself would hide every text; its senders are people (use Mute).
            let messages: Set = ["com.apple.mobilesms", "com.apple.ichat"]
            return event.appID.flatMap { messages.contains($0.lowercased()) ? nil : $0 }
        }
        return event.senderHandle.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// One source's problem in plain words (#186).
    static func health(_ line: SourceHealth.Line) -> String {
        let what = switch line.state {
        case .healthy: "fine"
        case .notInstalled: "not set up"
        case .permissionMissing: "Aegis isn't allowed to read it"
        case .formatChanged: "changed by a macOS update, so Aegis can't read it yet"
        case .transientFailure: "couldn't be read just now; retrying"
        case .stale: "not updated in the last half hour"
        }
        return name(line.source).uppercased() + " · " + what
    }

    /// "due today", "due tomorrow", "due Fri", "overdue since Tue", or nothing without a date (#182).
    static func due(_ date: Date?, now: Date, calendar: Calendar) -> String {
        guard let date else { return "" }
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = .autoupdatingCurrent
        format.dateFormat = "EEE"
        if date < now {
            return calendar.isDate(date, inSameDayAs: now) ? "due earlier today" : "overdue since " + format.string(from: date)
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return "due today"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "due tomorrow"
        }
        return "due " + format.string(from: date)
    }

    /// The brief as Aegis says it (#178): a greeting, urgent and reply items in full, then a count of the rest.
    static func spoken(_ brief: Brief, now: Date, calendar: Calendar) -> String {
        let hour = calendar.component(.hour, from: now)
        let greeting = hour < 12 ? "Good morning." : (hour < 17 ? "Good afternoon." : "Good evening.")
        let urgent = brief.items.filter { $0.priority == .urgent }.map(\.text)
        let reply = brief.items.filter { $0.priority == .reply }.map(\.text)
        let rest = brief.items.count - urgent.count - reply.count
        guard !brief.items.isEmpty else {
            return greeting + " Nothing needs you right now."
        }
        var parts = [greeting]
        if !urgent.isEmpty {
            parts
                .append((urgent.count == 1 ? "One urgent thing: " : "\(urgent.count) urgent things: ") + urgent
                    .joined(separator: " Next, "))
        }
        if !reply.isEmpty {
            parts.append((reply.count == 1 ? "One to reply to: " : "\(reply.count) to reply to: ") + reply.joined(separator: " Next, "))
        }
        if rest > 0 {
            parts
                .append(rest == 1 ? "And one more thing worth knowing, in the panel." :
                    "And \(rest) more things worth knowing, in the panel.")
        }
        return parts.joined(separator: " ")
    }

    /// The panel's title: an evening brief is the wrap-up, a morning one the brief (#172).
    static func title(storedAt: Date?, now: Date, calendar: Calendar) -> String {
        guard let storedAt else { return "MORNING BRIEF" }
        let hour = calendar.component(.hour, from: storedAt)
        if calendar.isDate(storedAt, inSameDayAs: now), hour >= 17 {
            return "EVENING WRAP-UP"
        }
        return hour < 12 ? "MORNING BRIEF" : "BRIEF"
    }

    /// The day the schedule shows: tomorrow from 5 pm, otherwise today.
    static func scheduleDay(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        guard calendar.component(.hour, from: now) >= 17 else { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
    }

    /// "3 h", "2 d", "20 min": how long someone has waited.
    static func waiting(since: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        if minutes < 60 {
            return "\(max(1, minutes)) min"
        }
        if minutes < 48 * 60 {
            return "\(minutes / 60) h"
        }
        return "\(minutes / 1440) d"
    }

    /// Why a question got no answer, in plain words (codes from AegisCore never carry collected text).
    /// Why no reply draft came back, in plain words (#176).
    static func draftMessage(_ code: String) -> String {
        switch code {
        case "busy": "Aegis is writing your brief. Try again in a minute."
        case "nothing_open": "Nothing from them is waiting on you now."
        case "unreachable", "unavailable": "Aegis's background part isn't reachable right now."
        case "timed_out", "cancelled": "That took too long. Try again."
        default: "Aegis couldn't write a draft it was sure of. Try again."
        }
    }

    static func askMessage(_ code: String) -> String {
        switch code {
        case "busy": "Aegis is writing your brief. Ask again in a minute."
        case "bad_question": "Try a shorter question."
        case "too_long": "That needs more than Aegis can read at once. Try narrowing it, for example to a person or a day."
        case "unreachable", "unavailable": "Aegis's background part isn't reachable right now."
        case "timedOut", "timed_out", "cancelled": "That took too long. Try again."
        case "unknown_citation", "invalid_draft", "unsafe_text": "I couldn't verify that answer against the available sources."
        case "model_missing": "My local language model isn't installed. Open setup to download it."
        case "model_corrupt": "My local language model couldn't load. It needs to be repaired in setup."
        case "out_of_memory": "There wasn't enough free memory to finish that answer."
        default: "My local language model didn't produce a usable answer. Please try again."
        }
    }

    static func heading(_ priority: Brief.Priority) -> String {
        switch priority {
        case .urgent: "NEEDS YOU TODAY"
        case .reply: "WAITING ON YOU"
        case .fyi: "WORTH KNOWING"
        }
    }

    /// One line per brief: how each source looked, so "nothing new" never hides "couldn't read".
    static func coverageLine(_ coverage: [SourceCoverage]) -> String {
        coverage.map { "\(name($0.source)) \(state($0))" }.joined(separator: " · ")
    }

    static func name(_ source: SourceKind) -> String {
        switch source {
        case .notifications: "Notifications"
        case .messages: "Messages"
        case .mail: "Mail"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .contacts: "Contacts"
        }
    }

    static func state(_ coverage: SourceCoverage) -> String {
        switch coverage.status {
        case .ok: "\(coverage.events) new"
        case .noData: "nothing new"
        case .notFound: "not set up"
        case .permissionDenied: "no access"
        case .busy: "busy, retrying"
        case .unreadable: "unreadable"
        case .formatChanged: "changed by a macOS update"
        case .stale: "not updated lately"
        }
    }

    /// "Written today, 6:58 am", "Written yesterday, 9:12 pm" or "Written 6 Oct, 7:00 am".
    static func written(_ date: Date, now: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        time.calendar = calendar
        let clock = date.formatted(time)
        if calendar.isDate(date, inSameDayAs: now) {
            return "Written today, \(clock)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Written yesterday, \(clock)"
        }
        var dayStyle = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .day().month(.abbreviated)
        dayStyle.timeZone = calendar.timeZone
        let day = date.formatted(dayStyle)
        return "Written \(day), \(clock)"
    }
}

/// Asking Aegis, and the memory list (#222).
extension PanelModel {
    func beginQuestion(_ question: String) -> UUID {
        let id = UUID()
        questionID = id
        handingOff = nil
        voice.stopSpeaking()
        askState = .asking(question)
        return id
    }

    func isCurrentQuestion(_ id: UUID) -> Bool {
        questionID == id && !Task.isCancelled
    }

    func finishQuestion(_ id: UUID) {
        guard questionID == id else { return }
        questionID = nil
        questionFinished()
    }

    func requestAnswer(_ trimmed: String, id: UUID) async {
        if let world = await worldAnswer(trimmed) {
            guard isCurrentQuestion(id) else { return }
            askState = .answered(question: trimmed, answer: world)
            return remember(Exchange(question: trimmed, answer: world, failure: nil))
        }
        // With a Claude or OpenAI key saved, AegisCore may hand the question off (#223).
        let available = CloudKeys.availability
        let request: CoreRequest = available.providers.isEmpty
            ? .ask(question: trimmed) : .converse(question: trimmed, cloud: available)
        let response = await service.handle(request)
        guard isCurrentQuestion(id) else { return }
        switch response {
        case let .handOff(approved):
            await handOff(approved, asked: trimmed, id: id)
        case let .answer(answer):
            askState = .answered(question: trimmed, answer: answer)
            remember(Exchange(question: trimmed, answer: answer, failure: nil))
        case let .refused(code):
            fail(trimmed, BriefPresentation.askMessage(code))
        default:
            fail(trimmed, BriefPresentation.askMessage("bad_reply"))
        }
    }

    /// Sends what AegisCore's gate approved to Claude or ChatGPT and shows the reply like any answer.
    private func handOff(_ request: CloudHandOff.Request, asked: String, id: UUID) async {
        if request.work == .task {
            await propose(request, asked: asked, id: id)
            return
        }
        handingOff = request.provider
        defer {
            if questionID == id {
                handingOff = nil
            }
        }
        let result: Result<(text: String, model: String), HandOffProblem> = if CloudKeys.viaPlan(request.provider) {
            switch await plan.answer(request) {
            case let .success(text): .success((text, request.provider.rawValue + "-plan"))
            case let .failure(failure): .failure(HandOffProblem(message: failure.message(request.provider)))
            }
        } else {
            switch await cloud.send(request) {
            case let .success(reply): .success((reply.text, reply.model))
            case let .failure(failure): .failure(HandOffProblem(message: failure.message(request.provider)))
            }
        }
        guard isCurrentQuestion(id) else { return }
        switch result {
        case let .success(reply):
            let answer = Answer(
                text: CloudHandOff.shown(reply.text), eventIDs: [], scheduleIDs: [], model: reply.model, generatedAt: Date()
            )
            askState = .answered(question: asked, answer: answer)
            remember(Exchange(question: asked, answer: answer, failure: nil))
            _ = await service.handle(.handedOff(question: request.question, reply: reply.text, provider: request.provider))
        case let .failure(problem):
            fail(asked, problem.message)
        }
    }

    // MARK: Tasks (#235)

    /// A task waits for the owner's Start: it makes files, so the action-safety policy asks first.
    private func propose(_ request: CloudHandOff.Request, asked: String, id: UUID) async {
        guard pendingTask == nil, runningTask == nil else {
            fail(asked, "Finish or cancel the current task first.")
            return
        }
        let name = CloudHandOff.folderName(for: request.question, now: Date(), calendar: .current)
            + " " + UUID().uuidString.prefix(8).lowercased()
        let task = PlanTask(request: request, asked: asked, folder: PlanRunner.tasksFolder.appendingPathComponent(name, isDirectory: true))
        let decision = await logAction(task, .proposed)
        guard isCurrentQuestion(id) else { return }
        guard decision.allowed else {
            fail(asked, "That's not something I can let \(request.provider.name) do.")
            return
        }
        let confirmation = await logAction(task, .awaitingConfirmation)
        guard isCurrentQuestion(id) else { return }
        guard confirmation.allowed else {
            fail(asked, "I couldn't record this task in the action log.")
            return
        }
        pendingTask = task
        let answer = Answer(
            text: "\(request.provider.name) can do this as a task in a new folder, Aegis Tasks › \(name). It can only "
                + "make changes inside that folder. Press Start when you're ready.",
            eventIDs: [], scheduleIDs: [], model: "aegis", generatedAt: Date()
        )
        askState = .answered(question: asked, answer: answer)
        remember(Exchange(question: asked, answer: answer, failure: nil))
    }

    /// The owner pressed Start.
    func startTask() async {
        guard var task = pendingTask, runningTask == nil else { return }
        pendingTask = nil
        task.started = Date()
        runningTask = task
        defer {
            runningTask = nil
            taskWork = nil
            taskViaPlan = false
        }
        do {
            try PlanRunner.createTaskFolder(task.folder, base: PlanRunner.tasksFolder)
        } catch {
            await logAction(task, .failed)
            fail("Task: " + task.asked, "I couldn't make the task's folder.")
            return
        }
        let viaPlan = CloudKeys.viaPlan(task.request.provider)
        taskViaPlan = viaPlan
        let work = Task<Result<String, HandOffProblem>, Never> { [task] in
            if viaPlan {
                switch await plan.task(task.request, in: task.folder, base: PlanRunner.tasksFolder) {
                case let .success(text): .success(text)
                case let .failure(failure): .failure(HandOffProblem(message: failure.message(task.request.provider)))
                }
            } else {
                // Through an API key the reply is saved in the folder as a Markdown file.
                switch await cloud.task(task.request, in: task.folder, base: PlanRunner.tasksFolder) {
                case let .success(text): .success(text)
                case let .failure(failure):
                    .failure(HandOffProblem(message: failure.message(task.request.provider)))
                }
            }
        }
        taskWork = work
        let completed = await work.value
        let result: Result<String, HandOffProblem> = work.isCancelled ? .failure(HandOffProblem(message: "Stopped.")) : completed
        switch result {
        case let .success(summary):
            await logAction(task, .succeeded)
            let answer = Answer(
                text: CloudHandOff.shown(summary), eventIDs: [], scheduleIDs: [],
                model: viaPlan ? task.request.provider.rawValue + "-plan" : task.request.provider.rawValue,
                generatedAt: Date()
            )
            remember(Exchange(question: "Task: " + task.asked, answer: answer, failure: nil, folder: task.folder))
        case let .failure(problem):
            await logAction(task, problem.message == "Stopped." ? .cancelled : .failed)
            fail("Task: " + task.asked, problem.message)
        }
    }

    /// The owner pressed Cancel before starting.
    func cancelTask() async {
        guard let task = pendingTask else { return }
        pendingTask = nil
        await logAction(task, .cancelled)
    }

    /// The owner pressed Stop while it ran.
    func stopTask() async {
        guard runningTask != nil else { return }
        taskWork?.cancel()
        if taskViaPlan {
            await plan.cancel()
        }
    }

    /// Records the task in the action log (#189): codes and IDs only, never the request's words.
    @discardableResult
    private func logAction(_ task: PlanTask, _ outcome: ActionOutcomeCode) async -> ActionDecision {
        let request = ActionRequest(id: task.actionID, payload: .file(path: task.folder.path, verb: .create), origin: .ownerTyped)
        let decision = ActionPolicy.decision(for: request, settings: .init(panelIsOpen: true, minimumTier: .confirm))
        guard let actions,
              await (try? actions.append(ActionLogEntry(time: Date(), request: request, decision: decision, outcomeCode: outcome))) != nil
        else { return .init(tier: .never, reasonCodes: [.unsupportedOperation]) }
        return decision
    }

    func loadPersonality() async {
        if case let .personality(current) = await service.handle(.personality) {
            personality = current
            Self.rememberWakeName(current.name)
        }
    }

    /// Saves the owner's choice; false when AegisCore refused it.
    func savePersonality(_ chosen: Personality) async -> Bool {
        guard case let .personality(saved) = await service.handle(.setPersonality(chosen)) else { return false }
        personality = saved
        Self.rememberWakeName(saved.name)
        return true
    }

    /// A one-word name is also a wake word; the wake listener reads it here.
    static let wakeNameKey = "wakeName"

    private static func rememberWakeName(_ name: String) {
        let word = name.split(separator: " ").count == 1 && name.lowercased() != "aegis" ? name : nil
        UserDefaults.aegis.set(word, forKey: wakeNameKey)
    }

    func reloadMemories() async {
        if case let .memories(notes) = await service.handle(.memories) {
            memories = notes
        }
    }

    func reloadMemoryViews() async {
        let groups = loadedSources
        sources = [:]
        loadedSources = []
        await reloadBrief()
        for ids in groups {
            await loadSources(ids: ids)
        }
    }

    /// Forgets one note from the panel's memory list (#222).
    func forget(_ note: MemoryNote) async {
        if case let .memories(notes) = await service.handle(.forgetMemory(id: note.id)) {
            memories = notes
            await reloadMemoryViews()
        }
    }
}
