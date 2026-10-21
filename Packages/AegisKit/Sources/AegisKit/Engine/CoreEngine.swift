import Foundation

/// AegisCore's engine (Stage 1 step 3.1). It feeds the brief scheduler its events, runs the actions the
/// scheduler returns against the collectors, the store and the model, and answers the panel.
///
/// Collected text stays data: the model only drafts, and a draft is published only after it validates
/// against the exact input it was given. Schedule changes run one at a time (a serial lane). Long work
/// (collection and generation) runs in the background holding the lane, so the minute ticker and the
/// panel's requests never wait for it: a tick past the deadline, or sleep, cancels the job at once. A
/// failed, invalid or cancelled job never replaces the last valid brief.
public actor CoreEngine: CoreService {
    public struct Options: Sendable {
        /// The model's name, recorded in each brief.
        public var modelName: String
        /// How far before the opening the brief looks back.
        public var lookback: TimeInterval
        public var maxTokens: Int
        /// Events read per store call while building the input.
        public var pageSize: Int
        /// How far before the window earlier messages are read as context for questions.
        public var contextLookback: TimeInterval = 3 * 86400
        /// Quiet seconds after a chat reply before Aegis learns from it (#282), while the model is still loaded.
        public var learnDelay: TimeInterval = 15

        public init(
            modelName: String, lookback: TimeInterval = 86400, maxTokens: Int = ModelJob.maxOutputTokens,
            pageSize: Int = 1000
        ) {
            self.modelName = modelName
            self.lookback = lookback
            self.maxTokens = maxTokens
            self.pageSize = pageSize
        }
    }

    let store: any EventStore
    let collectors: [any EventCollector]
    let contacts: (any ContactsProvider)?
    let rulesFile: (any OwnerRulesPersistence)?
    /// The owner's junk, "Not junk" and muted overrides (#175).
    var rules: OwnerRules
    let memoryFile: (any MemoryPersistence)?
    /// What the owner asked Aegis to remember, and past exchanges (#222).
    var memory: MemoryBook
    let personalityFile: (any PersonalityPersistence)?
    let routineFile: (any RoutinePersistence)?
    /// Recalls memory by meaning as well as words (#305); nil where no on-device model is available.
    let meaning: (any MeaningScorer)?
    /// On-device meaning vectors, kept in memory only and capped at 2,000 entries (#309).
    var meaningVectors: [String: [Float]] = [:]
    /// The morning routine and the owner's remembered decisions (#286).
    var routine: RoutineState
    /// Aegis's name and personality, set by the owner (#241).
    var personality: Personality
    let model: any ModelClient
    private let persistence: any SchedulePersistence
    let options: Options
    let calendar: Calendar
    let clock: @Sendable () -> Date

    private var schedule: BriefSchedule
    var coverage: [SourceKind: SourceCoverage] = [:]
    var sourceRetries: [SourceKind: SourceRetry] = [:]
    var sourceFirstAttempt: [SourceKind: Date] = [:]
    /// A draft that passed every check, waiting for the scheduler's `publishBrief`.
    var checked: (jobID: String, brief: StoredBrief)?
    private var deferredReason: String?
    /// A job that must not start (or continue) generating: sleep or a passed deadline came in while busy.
    var cancelRequested: String?
    private var work: Task<Void, Never>?
    var busy = false
    var generating: Bool {
        busy && schedule.job != nil
    }

    var waiting: [CheckedContinuation<Void, Never>] = []
    /// The owner's own addresses (#218), learned from their sent mail; with the Me card they mark the owner's mail.
    var ownerHandles: Set<String> = []
    var ownerLearned = false
    /// The conversation in the panel (#194): in memory only, forgotten after `Chat.memory`.
    var conversation: [Chat.Turn] = []
    /// The conversational reply being written, for speaking while thinking (#263).
    var replyJob: (id: String, question: String)?
    var conversationAt = Date.distantPast
    /// The owner's chat lines waiting to be learned from, the pending learning pass and its model job (#282).
    var learnQueue: [String] = []
    var learnTicket: UUID?
    var learnJobID: String?
    /// New owner questions supersede unfinished answers, including their history writes.
    var currentQuestion: UUID?
    var questionJobID: String?

    /// Restores the persisted schedule, or starts from `initial`.
    public init(
        store: any EventStore, collectors: [any EventCollector], model: any ModelClient,
        persistence: any SchedulePersistence, initial: BriefSchedule, options: Options,
        contacts: (any ContactsProvider)? = nil, rules: (any OwnerRulesPersistence)? = nil,
        memory: (any MemoryPersistence)? = nil, personality: (any PersonalityPersistence)? = nil,
        routine: (any RoutinePersistence)? = nil, meaning: (any MeaningScorer)? = nil,
        calendar: Calendar = Calendar(identifier: .gregorian),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.store = store
        self.collectors = collectors
        self.contacts = contacts
        rulesFile = rules
        self.rules = (try? rules?.load()) ?? .empty
        memoryFile = memory
        self.memory = (try? memory?.load()) ?? .empty
        personalityFile = personality
        self.personality = (try? personality?.load()) ?? .standard
        routineFile = routine
        self.meaning = meaning
        self.routine = (try? routine?.load()) ?? .empty
        self.model = model
        self.persistence = persistence
        self.options = options
        self.calendar = calendar
        self.clock = clock
        schedule = try persistence.load() ?? initial
    }

    /// After launch. Any earlier worker ended with the old process, so the scheduler may resume.
    public func start() async {
        _ = await begin(.resume(clock()))
    }

    /// About once a minute: starts the morning job on time and enforces deadlines. Never waits for work:
    /// while a job runs it only checks the deadline, and the scheduler sees the next free tick.
    public func tick() async {
        guard !busy else {
            if let job = schedule.job, clock() >= job.deadline {
                await requestCancel(job.id)
            }
            return
        }
        _ = await begin(.tick(clock()))
        retrySourcesIfDue()
    }

    public func wake() async {
        _ = await begin(.wake(clock()))
    }

    /// Heat or Low Power Mode: while either holds, new generation waits; it resumes when both clear.
    public func conditions(thermalSerious: Bool, lowPower: Bool) async {
        _ = await begin(.conditions(thermalSerious: thermalSerious, lowPower: lowPower, at: clock()))
    }

    /// The Mac is going to sleep: a running or about-to-run job is cancelled at once; the last brief stays.
    public func sleep() async {
        if busy, let job = schedule.job {
            await requestCancel(job.id)
        }
        await acquire()
        await send(.sleep(clock()))
        release()
    }

    /// Waits for background work (tests and orderly shutdown).
    public func settle() async {
        while let task = work {
            work = nil
            await task.value
        }
    }

    func status() -> CoreStatus {
        let now = clock()
        var next = schedule.opening(on: now, calendar: calendar)
        if let opening = next, opening <= now {
            next = schedule.opening(on: now.addingTimeInterval(86400), calendar: calendar)
        }
        let busyStates: [ScheduleState] = [.refreshing, .generating, .cancelling]
        return CoreStatus(
            sources: sourceCoverage(at: now),
            lastBriefAt: schedule.lastBriefAt,
            nextBriefAt: next,
            generating: busyStates.contains(schedule.state)
        )
    }

    // MARK: Starting work

    private enum Begun {
        case started
        case refused(String)
    }

    /// Takes the lane, applies `event`, and runs its actions: quick ones here, collection and generation in
    /// a background task that keeps the lane until it ends.
    private func begin(_ event: ScheduleEvent) async -> Begun {
        await acquire()
        let previous = schedule
        let actions = step(&schedule, event, calendar: calendar)
        guard save() else {
            // Never start work the schedule file can't record.
            schedule = previous
            release()
            return .refused("schedule_unwritable")
        }
        for case let .refused(code) in actions {
            release()
            return .refused(code)
        }
        let long = actions.contains {
            switch $0 {
            case .refreshSources, .startGeneration: true
            default: false
            }
        }
        guard long else {
            await execute(actions)
            release()
            return .started
        }
        work = Task {
            await self.execute(actions)
            self.release()
        }
        return .started
    }

    func requestCancel(_ jobID: String) async {
        cancelRequested = jobID
        await model.cancel(jobID: jobID)
    }

    /// Owner questions take priority over a background brief, which retains its previous valid result.
    func interruptBriefForQuestion() async {
        if let job = schedule.job, busy {
            await requestCancel(job.id)
        }
    }

    // MARK: Running the scheduler's actions (always inside the lane)

    private func send(_ event: ScheduleEvent) async {
        let previous = schedule
        var actions = step(&schedule, event, calendar: calendar)
        var published = false
        if let index = actions.firstIndex(where: {
            if case .publishBrief = $0 {
                true
            } else {
                false
            }
        }), case let .publishBrief(jobID) = actions[index] {
            guard await publishChecked(jobID) else {
                // Nothing was stored, and no worker is left to finish the reservation: record the attempt as
                // failed, so the scheduler keeps the old brief and retries after its backoff.
                schedule = previous
                checked = nil
                await send(.jobFinished(jobID: jobID, outcome: .failed, duration: 0, at: clock()))
                return
            }
            actions.remove(at: index)
            published = true
        }
        if !save(), !published {
            // A transition the schedule file can't record never runs; the engine stays where the file is.
            schedule = previous
            return
        }
        // After a publish the brief is already stored, so the new state stands even if this save failed:
        // the next transition writes it, and a restart from the older file only retries (a duplicate brief).
        await execute(actions)
    }

    private func execute(_ actions: [ScheduleAction]) async {
        for action in actions {
            switch action {
            case .refreshSources:
                await refreshSources()
            case let .startGeneration(jobID):
                await generate(jobID)
            case .publishBrief:
                break // Handled in `send`, before the new state is saved.
            case let .cancelJob(jobID):
                await model.cancel(jobID: jobID)
            case .keepPreviousBrief:
                checked = nil
            case let .publishDeferred(reason):
                deferredReason = reason
            case .refused:
                break
            }
        }
    }

    private func refreshSources() async {
        guard let job = schedule.job else {
            return
        }
        await collectSources()
        let at = clock()
        await send(.sourcesRefreshed(jobID: job.id, inputTime: at, at: at))
    }

    /// Retries on the existing minute ticker; no extra timer, model job or busy loop.
    private func retrySourcesIfDue() {
        guard !busy, schedule.isAwake, sourceRetries.values.contains(where: { $0.nextAttempt <= clock() }) else { return }
        busy = true
        work = Task {
            await self.collectSources(retriesOnly: true)
            self.release()
        }
    }

    private func generate(_ jobID: String) async {
        guard let job = schedule.job, job.id == jobID else {
            return
        }
        let started = clock()
        // Sleep or the deadline may have come in while the sources were read: don't start the model.
        let outcome = cancelRequested == jobID ? .cancelled : await draft(job)
        cancelRequested = nil
        let finished = clock()
        await send(.jobFinished(
            jobID: jobID, outcome: outcome, duration: finished.timeIntervalSince(started), at: finished
        ))
    }

    private func publishChecked(_ jobID: String) async -> Bool {
        guard let checked, checked.jobID == jobID else {
            return false
        }
        self.checked = nil
        do {
            try await store.saveBrief(checked.brief)
            return true
        } catch {
            return false
        }
    }

    private func save() -> Bool {
        do {
            try persistence.save(schedule)
            return true
        } catch {
            return false
        }
    }
}

extension CoreEngine {
    func refreshBrief() async -> CoreResponse {
        // While a job holds the lane the slot is taken: answer now, as the scheduler would.
        if busy, schedule.job != nil {
            return .refused(code: "already_generating")
        }
        switch await begin(.userRefresh(clock())) {
        case let .refused(code):
            return .refused(code: code)
        case .started:
            return .accepted(jobID: schedule.job?.id ?? "")
        }
    }
}
