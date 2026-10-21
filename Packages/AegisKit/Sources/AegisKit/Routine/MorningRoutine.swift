import Foundation

/// The morning routine (#286), adapted from OpenJarvis's proactive agent (agents/proactive_agent.py, Apache-2.0):
/// when the panel first opens each day, Aegis proposes a few jobs and the owner answers yes, no, always yes or always
/// no. Unlike OpenJarvis, no model reads collected messages to invent actions: proposals come from the owner's own
/// data (remembered dates, their own promises, rule suggestions, skills they scheduled), and nothing runs while the
/// panel is closed.
public struct MorningRoutine: Codable, Sendable, Hashable {
    /// The day these proposals belong to (start of the day).
    public var day: Date
    /// Numbered from 1 in the order shown; numbers stay stable for the day.
    public var proposals: [RoutineProposal]

    public init(day: Date, proposals: [RoutineProposal] = []) {
        self.day = day
        self.proposals = proposals
    }

    /// Proposals still waiting for the owner.
    public var pending: [RoutineProposal] {
        proposals.filter { $0.status == .pending }
    }

    /// Approved proposals the app still has to carry out (reminders and skills).
    public var toRun: [RoutineProposal] {
        proposals.filter { $0.status == .approved }
    }
}

/// One proposed job (OpenJarvis's PendingAction).
public struct RoutineProposal: Codable, Sendable, Hashable, Identifiable {
    /// What approving it does. Reminders and skills run in the app; rules are applied by AegisCore.
    public enum Action: Codable, Sendable, Hashable {
        case reminder(title: String, due: Date?)
        case rule(RuleSuggestion)
        case skill(name: String)
    }

    /// Twelve hex characters, as in OpenJarvis; stable for the same job on the same day.
    public let id: String
    public var number: Int
    public let action: Action
    /// One short sentence, shown on the card and read aloud.
    public let text: String
    public let permissionKey: String
    public let tier: ApprovalTier
    public var status: ProposalStatus
    /// Approved by an earlier "always yes", without asking today.
    public var remembered: Bool

    public init(
        id: String, number: Int, action: Action, text: String, permissionKey: String, tier: ApprovalTier,
        status: ProposalStatus = .pending, remembered: Bool = false
    ) {
        self.id = id
        self.number = number
        self.action = action
        self.text = text
        self.permissionKey = permissionKey
        self.tier = tier
        self.status = status
        self.remembered = remembered
    }

    /// A stable ID from the pattern and what the job is about; with `day`, a new one each day (skills).
    public static func id(_ key: String, _ subject: String, day: Date?) -> String {
        String(SHA256.hex(Array("\(key)|\(subject)|\(day.map { String(Int($0.timeIntervalSince1970)) } ?? "")".utf8)).prefix(12))
    }
}

/// What the morning routine is built from: all owner-side data AegisCore already has.
public struct RoutineInputs: Sendable {
    public var memory: MemoryBook
    public var commitments: [Commitment]
    public var suggestions: [RuleSuggestion]
    /// Names of skills the owner scheduled for today (the app adds these).
    public var skills: [String]

    public init(memory: MemoryBook = .empty, commitments: [Commitment] = [], suggestions: [RuleSuggestion] = [], skills: [String] = []) {
        self.memory = memory
        self.commitments = commitments
        self.suggestions = suggestions
        self.skills = skills
    }
}

public extension MorningRoutine {
    /// At most this many proposals a day.
    static let maxProposals = 8

    /// Today's candidates, before remembered decisions: scheduled skills, remembered dates in the next three days,
    /// the owner's promises due by tomorrow, then rule suggestions.
    static func candidates(_ inputs: RoutineInputs, now: Date, calendar: Calendar) -> [RoutineProposal] {
        let day = calendar.startOfDay(for: now)
        var found: [RoutineProposal] = inputs.skills.map { name in
            proposal(
                .skill(name: name), text: "Run your “\(name)” skill", key: "skill:\(name)", subject: name, tier: .low, day: day
            )
        }
        for upcoming in inputs.memory.upcoming(now: now, calendar: calendar, within: 3) {
            let title = MemoryText.sentence(upcoming.note.text).trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
            let due = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: upcoming.days == 0 ? now : upcoming.date)
            found.append(proposal(
                .reminder(title: title, due: due), text: "Add a reminder: " + upcoming.line,
                key: "reminder:remembered-date", subject: upcoming.note.id, tier: .low, day: day
            ))
        }
        let soon = calendar.date(byAdding: .day, value: 2, to: day) ?? now
        for promise in inputs.commitments where promise.due.map({ $0 < soon }) ?? false {
            let title = "\(promise.person): \(promise.text)"
            found.append(proposal(
                .reminder(title: title, due: promise.due), text: "Add a reminder for what you told \(promise.person)",
                key: "reminder:my-promise", subject: promise.eventID, tier: .low, day: day
            ))
        }
        for suggestion in inputs.suggestions {
            let verb = suggestion.kind == .vip ? "Make \(suggestion.name) a VIP" : "Mute \(suggestion.name)"
            found.append(proposal(
                .rule(suggestion), text: verb + ": " + suggestion.reason.prefix(1).lowercased() + suggestion.reason.dropFirst(),
                key: "rule:\(suggestion.kind.rawValue):\(suggestion.personID)", subject: suggestion.personID, tier: .medium, day: day
            ))
        }
        return found
    }

    /// Adds new candidates to today's routine (or starts a new day), numbering them after the existing ones and
    /// applying remembered decisions: "always no" drops a proposal unseen, "always yes" approves it.
    mutating func merge(_ candidates: [RoutineProposal], approvals: Approvals, now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        if day != today {
            self = MorningRoutine(day: today)
        }
        let known = Set(proposals.map(\.id))
        for var candidate in candidates where !known.contains(candidate.id) && proposals.count < Self.maxProposals {
            switch approvals.decision(for: candidate.permissionKey) {
            case .alwaysDeny where candidate.tier.canRemember:
                continue
            case .alwaysApprove where candidate.tier.canRemember:
                candidate.status = .approved
                candidate.remembered = true
            default:
                candidate.status = candidate.tier == .trivial ? .approved : .pending
            }
            candidate.number = proposals.count + 1
            proposals.append(candidate)
        }
    }

    private static func proposal(
        _ action: RoutineProposal.Action, text: String, key: String, subject: String, tier: ApprovalTier, day: Date
    ) -> RoutineProposal {
        // A skill is offered each day; a reminder or rule only until the owner has answered it.
        let perDay = if case .skill = action {
            true
        } else {
            false
        }
        return RoutineProposal(
            id: RoutineProposal.id(key, subject, day: perDay ? day : nil),
            number: 0,
            action: action,
            text: text,
            permissionKey: key,
            tier: tier
        )
    }
}
