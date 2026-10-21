import Foundation

/// A brief as AegisCore stores and serves it: the checked brief plus where it came from and how complete
/// its sources were (Stage 1, #64).
public struct StoredBrief: Codable, Sendable, Hashable {
    public var brief: Brief
    /// The snapshot its input came from; every citation refers to an event in it.
    public var inputRevision: String
    public var coverage: [SourceCoverage]
    public var storedAt: Date

    public init(brief: Brief, inputRevision: String, coverage: [SourceCoverage], storedAt: Date) {
        self.brief = brief
        self.inputRevision = inputRevision
        self.coverage = coverage
        self.storedAt = storedAt
    }
}

/// What AegisCore reports about itself to the panel. Numbers and states only.
public struct CoreStatus: Codable, Sendable, Hashable {
    public var sources: [SourceCoverage]
    public var lastBriefAt: Date?
    public var nextBriefAt: Date?
    public var generating: Bool

    public init(sources: [SourceCoverage], lastBriefAt: Date?, nextBriefAt: Date?, generating: Bool) {
        self.sources = sources
        self.lastBriefAt = lastBriefAt
        self.nextBriefAt = nextBriefAt
        self.generating = generating
    }
}

/// Why a new brief was asked for.
public enum RefreshReason: String, Codable, Sendable, CaseIterable {
    case user, schedule, wake
}

/// A request to AegisCore from the panel. There is no request that acts on the owner's accounts.
public enum CoreRequest: Codable, Sendable, Hashable {
    case latestBrief
    case status
    case refreshBrief(reason: RefreshReason)
    /// The panel opened (#209): load the model now so the first answer doesn't wait for it. Replies `.accepted`
    /// at once; read-only.
    case prepareModel
    /// The events a brief item cites, to show and open them (at most `maxSourceIDs`).
    case sources(ids: [String])
    /// Calendar occurrences and reminders in a window (at most `maxScheduleDays`), straight from EventKit.
    case schedule(from: Date, to: Date)
    /// A question typed in the panel (#163), answered only from the owner's own data on the Mac. Read-only:
    /// no request acts on anything. At most `maxQuestionScalars`.
    case ask(question: String)
    /// Plan God's Eye View page actions from the owner's own words about the globe (#296, additive).
    /// At most `maxQuestionScalars`; never collected content, conversation memory or a cloud hand-off.
    /// Replies `worldPlan`. Refusals: bad_question, too_long, unavailable, invalid_plan, or model status codes.
    case worldPlan(question: String)
    /// Recent contact with this meeting's attendees (#184, additive, read-only); replies with `answer`.
    /// Refusals: unknown_occurrence, busy, Ask's rejection codes, model status, or unavailable.
    case prep(occurrenceID: String)
    /// Interpret only the owner's panel input as a local visibility rule (#179, additive). Read-only:
    /// replies with a proposal awaiting a click, or not_a_command, no_match, ambiguous, store_unavailable.
    /// One sentence of at most `RuleCommands.maxScalars`; applying uses the existing rule requests.
    case interpret(text: String)
    /// Who is waiting on the owner (#165): open questions per person or group chat, oldest first.
    case people
    /// Open promises in the owner's outgoing messages and emails (#182, additive, read-only).
    /// At most 12, overdue first; a store error refuses with `store_unavailable`.
    case commitments
    /// Today's answered questions, kept promises, completed reminders and held events (#211, read-only).
    /// At most 20, newest first; a store error refuses with `store_unavailable`.
    case done
    /// Suggest a reply to this person's open questions (#176, additive). Never sends anything.
    /// IDs have a contact:/group:/handle: prefix and at most 320 scalars. Refusals: bad_person,
    /// nothing_open, busy, invalid_draft, unknown_citation, too_long, unsafe_text, failed, timed_out, cancelled.
    case draftReply(personID: String)
    /// What Aegis treated as junk in the last day (#167), grouped by sender.
    case filtered
    /// "Not junk": remove explicit junk and bypass automatic noise (a local Aegis setting, #167).
    /// Invalid handles refuse with `bad_handle`; failed saves with `rules_unwritable` (#175).
    case trustSender(handle: String)
    /// The owner's local junk, trusted and muted rules (#175, additive).
    case rules
    /// Habit-based priority/visibility proposals (#278, additive, read-only). At most three, strongest first;
    /// never applied automatically. Replies `ruleSuggestions`, or `store_unavailable` on a failed read.
    case ruleSuggestions
    /// Ignore this proposal for 30 calendar days (#278); replies with remaining `ruleSuggestions`.
    /// IDs follow `mute` (at most 320 scalars); refusals: bad_person, rules_unwritable, store_unavailable.
    /// Accepting instead uses the existing `vip` or `mute` request and requires an explicit owner decision.
    case dismissSuggestion(personID: String, kind: RuleSuggestion.Kind)
    /// Today's morning routine (#286, additive): proposals from the owner's own data, with remembered decisions
    /// applied. `skills` names the owner's skills scheduled for now (at most 10). Replies `morningRoutine`;
    /// refusals: bad_skill, routine_unwritable.
    case morningRoutine(skills: [String])
    /// The owner's yes or no to proposals by ID (#286); `always` remembers it for low and medium tiers. Approving a
    /// rule applies it; reminders and skills are then run by the app. Refusals: bad_routine, routine_unwritable.
    case decideRoutine(ids: [String], approved: Bool, always: Bool)
    /// The app ran an approved reminder or skill (#286). Refusals: bad_routine, routine_unwritable.
    case routineDone(id: String, succeeded: Bool)
    /// Mark a sender junk; replies with the updated Filtered list (#175, additive).
    /// Invalid handles refuse with `bad_handle`; failed saves with `rules_unwritable`.
    case markJunk(handle: String)
    /// Hide this person or group from brief and waiting lists; replies with saved rules (#175, additive).
    /// Invalid IDs or names refuse with `bad_person`; failed saves with `rules_unwritable`.
    case mute(personID: String, name: String)
    /// Undo a mute; replies with saved rules (#175, additive).
    /// Invalid IDs refuse with `bad_person`; failed saves with `rules_unwritable`.
    case unmute(personID: String)

    /// Prioritise an incoming person's messages; replies with saved rules (#185, additive).
    /// Validation and refusals match `mute`; mute and junk still hide the person's messages.
    case vip(personID: String, name: String)
    /// Remove VIP priority; replies with saved rules. Refusals match `unmute`.
    case unvip(personID: String)
    /// Add or replace a trimmed 2–60 scalar phrase, up to 50 rules; replies with saved rules.
    /// Invalid phrases or a full list refuse `bad_keyword`; failed saves refuse `rules_unwritable`.
    case addKeyword(phrase: String, effect: KeywordRule.Effect)
    /// Remove a case-insensitive phrase; replies with saved rules. Refusals match `addKeyword`.
    case removeKeyword(phrase: String)
    /// `ask` when the panel can hand off to Claude or ChatGPT (#223, additive, ADR-0017): the same answers, or
    /// `handOff` with exactly what may leave the Mac. Personal questions are never handed off.
    case converse(question: String, cloud: CloudHandOff.Availability)
    /// A hand-off's reply, kept in the conversation for follow-ups and in memory's exchanges (#223, additive).
    /// Replies `accepted`.
    case handedOff(question: String, reply: String, provider: CloudHandOff.Provider)
    /// The finished, checked sentences of the conversational reply being written (#263, additive, read-only):
    /// replies `partialReply`, empty when none is being written. Polled by the panel to speak while thinking.
    case partialReply
    /// Aegis's name and personality (#241, additive); replies with `personality`.
    case personality
    /// Save the owner's choice of name and personality; replies with the saved `personality`. Refusals:
    /// bad_personality (an empty or over-long name, or over-long notes), personality_unwritable.
    case setPersonality(Personality)
    /// What the owner asked Aegis to remember, newest first (#222, additive); replies with `memories`.
    case memories
    /// Forget one note; replies with the remaining `memories`. Refusals: bad_memory (an ID over 64 scalars),
    /// unknown_memory, memory_unwritable.
    case forgetMemory(id: String)

    /// The most IDs one `sources` request may ask for.
    public static let maxSourceIDs = 20
    /// The longest window one `schedule` request may ask for, in days.
    public static let maxScheduleDays = 7
    /// The longest question, in Unicode scalars.
    public static let maxQuestionScalars = 500
}

/// AegisCore's answer.
public enum CoreResponse: Codable, Sendable, Hashable {
    case brief(StoredBrief?)
    case status(CoreStatus)
    /// A refresh was queued as this job.
    case accepted(jobID: String)
    /// A refresh couldn't be queued; the code says why (for example `already_generating`).
    case refused(code: String)
    /// The answer to an `ask` (#163) or meeting `prep` (#184).
    case answer(Answer)
    /// Checked God's Eye View actions in order (#296, additive), at most `WorldActions.maxActions`.
    /// Empty actions means this isn't a globe request. `say` is an optional short sentence for the owner.
    case worldPlan(actions: [WorldAction], say: String?)
    /// A checked suggestion for the owner to copy (#176, additive); never an action.
    case draft(ReplyDraft)
    /// A visibility rule awaiting the owner's click (#179, additive); never applied by interpretation.
    case proposal(RuleProposal)
    /// Who is waiting on the owner (#165).
    case people([PersonWaiting])
    /// The owner's still-open promises (#182, additive); never instructions to act.
    case commitments([Commitment])
    /// Record-based completions in the owner's local day (#211); never instructions to act.
    case done([DoneItem])
    /// What Aegis treated as junk (#167); also the reply to `trustSender` and `markJunk`.
    case filtered([FilteredSender])
    /// The saved owner rules; reply to reads and person/keyword rule changes (#185, additive).
    case rules(OwnerRules)
    /// Today's morning routine (#286).
    case morningRoutine(MorningRoutine)
    /// Suggestions awaiting the owner's choice (#278); no rule has been applied by computing these.
    case ruleSuggestions([RuleSuggestion])
    /// The requested events that are still stored (unknown IDs are left out).
    case events([Event])
    /// The schedule in a window: occurrences overlapping it, and reminders open or completed in it.
    case schedule(occurrences: [CalendarOccurrence], reminders: [ReminderItem])
    /// The owner's memory notes, newest first (#222, additive).
    case memories([MemoryNote])
    /// Aegis's name and personality (#241, additive).
    case personality(Personality)
    /// The speakable start of the reply being written (#263); always a prefix of the final reply's text.
    case partialReply(String)
    /// A question for Claude or ChatGPT, checked by AegisCore's gate; the panel sends it with the owner's key
    /// (#223, additive). It holds only the owner's words and earlier non-personal turns of the same hand-off.
    case handOff(CloudHandOff.Request)
}

/// The one way Aegis's processes encode messages to each other, so both ends always agree.
public enum IPCCoding {
    /// Encodes a message for XPC.
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// Decodes a message from XPC.
    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}
