import AegisKit
import Foundation

/// Stands in for AegisCore until its XPC service exists (#67). Synthetic data only: the contract's example
/// brief, labelled "SAMPLE" in the panel so it can't be mistaken for the owner's day.
struct SampleCoreService: CoreService {
    // The service fake intentionally exhausts the additive wire contract.
    // swiftlint:disable:next cyclomatic_complexity
    func handle(_ request: CoreRequest) async -> CoreResponse {
        switch request {
        case .latestBrief:
            .brief(Self.brief(now: Date()))
        case .status, .setBriefTime:
            .status(CoreStatus(sources: Self.coverage(now: Date()), lastBriefAt: Date(), nextBriefAt: nil, generating: false))
        case .prepareModel:
            .accepted(jobID: "sample")
        case .refreshBrief:
            .refused(code: "sample_data")
        case .sources:
            // The sample has no stored messages behind it.
            .events([])
        case .schedule:
            .schedule(occurrences: [], reminders: [])
        case .filtered:
            .filtered([FilteredSender(
                sender: "Example Store", handle: "deals@example.com", reason: .promotion, count: 3,
                latest: "SALE 50% at Example Store", eventIDs: []
            )])
        case .trustSender, .markJunk:
            .filtered([])
        case let .draftReply(personID):
            .draft(ReplyDraft(
                person: Brief.Person(id: personID, name: "Alex Example"), text: "Sure, call me after [time] on Saturday.",
                eventIDs: ["ev_f403382210fbc3b8"], model: nil, generatedAt: Date()
            ))
        case .commitments:
            .commitments([Commitment(
                personID: "contact:sample-alex", person: "Alex Example", text: "I'll send you the plan tomorrow",
                due: Calendar.current.date(byAdding: .day, value: 1, to: Date()), madeAt: Date().addingTimeInterval(-3600),
                eventID: "ev_f403382210fbc3b8"
            )])
        case .interpret:
            .refused(code: "not_a_command")
        case .done:
            .done([])
        case .ruleSuggestions, .dismissSuggestion:
            .ruleSuggestions([])
        case .morningRoutine, .decideRoutine, .routineDone:
            .morningRoutine(MorningRoutine(day: Calendar.current.startOfDay(for: Date())))
        case .rules, .mute, .unmute, .vip, .unvip, .addKeyword, .removeKeyword:
            // The sample keeps no rules: a mute shows nothing new.
            .rules(.empty)
        case .people:
            .people([PersonWaiting(
                person: Brief.Person(id: "contact:sample-alex", name: "Alex Example"),
                waitingSince: Date().addingTimeInterval(-3 * 3600), questions: 1,
                latest: "Can you call me about Saturday?", eventIDs: ["ev_f403382210fbc3b8"]
            )])
        case .ask, .converse:
            .answer(Answer(
                text: "Alex Example asked you to call about Saturday.", eventIDs: ["ev_f403382210fbc3b8"], scheduleIDs: [],
                model: nil, generatedAt: Date()
            ))
        case .prep:
            .refused(code: "sample_data")
        case .worldPlan:
            .worldPlan(actions: [], say: nil)
        case .memories, .forgetMemory:
            .memories([])
        case .personality, .setPersonality:
            .personality(.standard)
        case .partialReply:
            .partialReply("")
        case .handedOff:
            .accepted(jobID: "sample")
        case let .activity(hours):
            .activity(Self.activity(hours: hours, now: Date()))
        }
    }

    /// A made-up day's rhythm, counts only: quiet overnight, busy through the working day.
    static func activity(hours: Int, now: Date, calendar: Calendar = .current) -> HourlyActivity {
        let count = min(max(hours, 1), CoreRequest.maxActivityHours)
        let current = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let start = current.addingTimeInterval(-Double(count - 1) * 3600)
        let rhythm = [0, 0, 0, 0, 0, 1, 3, 8, 12, 10, 9, 11, 7, 9, 12, 10, 8, 6, 5, 4, 3, 2, 1, 0]
        func series(_ scale: Int) -> [Int] {
            (0 ..< count).map { rhythm[calendar.component(.hour, from: start.addingTimeInterval(Double($0) * 3600))] * scale / 4 }
        }
        return HourlyActivity(start: start, counts: [.notification: series(6), .imessage: series(3), .email: series(4)])
    }

    static func brief(now: Date) -> StoredBrief {
        let items: [Brief.Item] = [
            .init(text: "Invoice 1043 from Jordan Sample ($1,250.00) is due Friday.", priority: .urgent, eventIDs: ["ev_67d18655edf43ac7"]),
            .init(text: "Alex Example asked you to call about Saturday.", priority: .reply, eventIDs: ["ev_f403382210fbc3b8"]),
            .init(text: "Storm warning for your area this afternoon.", priority: .fyi, eventIDs: ["ev_3b6e2c1f0d9a8e77"]),
        ]
        let brief = Brief(
            generatedAt: now,
            windowStart: now.addingTimeInterval(-86400),
            windowEnd: now,
            model: "sample",
            items: items,
            omittedEvents: 0
        )
        return StoredBrief(brief: brief, inputRevision: "sample", coverage: coverage(now: now), storedAt: now)
    }

    static func coverage(now: Date) -> [SourceCoverage] {
        [
            SourceCoverage(source: .messages, status: .ok, events: 5, lastSuccess: now),
            SourceCoverage(source: .mail, status: .noData, events: 0, lastSuccess: now),
            SourceCoverage(source: .notifications, status: .ok, events: 9, lastSuccess: now),
        ]
    }
}
