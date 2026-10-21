import AegisKit
import Foundation
import Observation

/// Today's morning routine as the panel shows it (#286).
@MainActor
@Observable
final class RoutinePresence {
    static let shared = RoutinePresence()
    var today: MorningRoutine?
    /// When Aegis last read the proposals out, so a bare "yes" can answer them.
    @ObservationIgnored var listedAt: Date?
    /// Approved jobs being carried out, so a second refresh doesn't run them twice.
    @ObservationIgnored var running: Set<String> = []

    var pending: [RoutineProposal] {
        today?.pending ?? []
    }
}

/// The morning routine (#286), after OpenJarvis's proactive agent: built when the panel opens, never while it's
/// closed. The owner answers on the card or in their own words ("yes to 1 and 3", "always no to the second one").
extension PanelModel {
    /// Asks AegisCore for today's routine and carries out anything already approved.
    func refreshRoutine() async {
        guard case let .morningRoutine(today) = await service.handle(.morningRoutine(skills: dueSkillNames())) else { return }
        RoutinePresence.shared.today = today
        await runApproved(origin: .ownerTyped)
    }

    /// The owner's answer from the card.
    func decideRoutine(_ proposals: [RoutineProposal], approved: Bool, always: Bool) async {
        let reply = await decide(proposals, approved: approved, always: always, origin: .ownerTyped)
        askState = .answered(question: approved ? "Yes" : "No", answer: Self.said(reply))
    }

    /// "What's my morning routine?", or an answer to it; nil when the question is neither.
    func routineAnswer(_ question: String, origin: ActionOrigin) async -> Answer? {
        let presence = RoutinePresence.shared
        let pending = presence.pending
        if question.range(of: Self.listPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            presence.listedAt = Date()
            return Self.said(Self.listing(pending))
        }
        guard !pending.isEmpty else { return nil }
        let recentlyListed = presence.listedAt.map { Date().timeIntervalSince($0) < 300 } ?? false
        let decisions = ApprovalReply.parse(question, single: pending.count == 1 && recentlyListed)
        guard !decisions.isEmpty else { return nil }
        var replies: [String] = []
        for decision in decisions {
            let chosen: [RoutineProposal] = switch decision.target {
            case .all: pending
            case let .number(number): pending.filter { $0.number == number }
            case let .id(id): pending.filter { $0.id == id }
            }
            guard !chosen.isEmpty else { continue }
            await replies.append(decide(chosen, approved: decision.approved, always: decision.always, origin: origin))
        }
        return replies.isEmpty ? nil : Self.said(replies.joined(separator: " "))
    }

    // MARK: - Steps

    private func decide(_ proposals: [RoutineProposal], approved: Bool, always: Bool, origin: ActionOrigin) async -> String {
        let ids = proposals.map(\.id)
        guard case let .morningRoutine(today) = await service.handle(.decideRoutine(ids: ids, approved: approved, always: always))
        else { return "I couldn't save that. Please try again." }
        RoutinePresence.shared.today = today
        await runApproved(origin: origin)
        let count = proposals.count == 1 ? "that" : "those \(proposals.count)"
        let remembered = always && proposals.contains { $0.tier.canRemember }
            ? (approved ? " I'll do jobs like \(proposals.count == 1 ? "that" : "these") without asking from now on."
                : " I won't suggest jobs like \(proposals.count == 1 ? "that" : "these") again.")
            : ""
        return (approved ? "Done: \(count)." : "Okay, skipping \(count).") + remembered
    }

    /// Carries out approved reminders (and skills) once each, then tells AegisCore.
    private func runApproved(origin: ActionOrigin) async {
        let presence = RoutinePresence.shared
        for proposal in presence.today?.toRun ?? [] where !presence.running.contains(proposal.id) {
            presence.running.insert(proposal.id)
            defer { presence.running.remove(proposal.id) }
            let succeeded: Bool
            switch proposal.action {
            case let .reminder(title, due):
                let command = ActionCommand.reminder(title: title, due: due)
                let request = ActionRequest(payload: command.payload, origin: origin)
                guard await log(request, .proposed).allowed else {
                    succeeded = false
                    break
                }
                let failure = await Self.add(command)
                await log(request, failure == nil ? .succeeded : .failed)
                succeeded = failure == nil
            case let .skill(name):
                succeeded = await runSkill(named: name)
            case .rule:
                continue
            }
            if case let .morningRoutine(today) = await service.handle(.routineDone(id: proposal.id, succeeded: succeeded)) {
                presence.today = today
            }
        }
    }

    private static let listPattern = #"^(?:(?:hey |ok |okay )?aegis,? )?(?:what(?:'s| is) (?:my|the|today's) morning routine|"#
        + #"what do you (?:suggest|propose)(?: (?:today|this morning|for today))?|(?:show|read) (?:me )?(?:my |the )?morning routine|"#
        + #"morning routine)[?.!]*$"#

    private static func listing(_ pending: [RoutineProposal]) -> String {
        guard !pending.isEmpty else { return "Nothing to suggest this morning." }
        let items = pending.map { "\($0.number), \($0.text)" }.joined(separator: "; ")
        let lead = pending.count == 1 ? "One suggestion: " : "\(pending.count) suggestions: "
        return lead + items + ". Say yes or no, with a number, or “always yes” to stop me asking."
    }
}
