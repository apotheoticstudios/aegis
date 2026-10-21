import Foundation

/// The morning routine (#286), after OpenJarvis's proactive agent and approval store (Apache-2.0). Built only when
/// the panel asks for it, from the owner's own data; rules are applied here, reminders and skills by the app.
extension CoreEngine {
    /// Answered jobs are not offered again for this long.
    static let routineMemory: TimeInterval = 30 * 86400

    func morningRoutine(skills: [String]) async -> CoreResponse {
        guard skills.count <= 10, skills.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.count <= 64 }) else {
            return .refused(code: "bad_skill")
        }
        let now = clock()
        let commitments = if case let .commitments(open) = await commitments() {
            open
        } else {
            [Commitment]()
        }
        let suggestions = if case let .ruleSuggestions(found) = await ruleSuggestions() {
            found
        } else {
            [RuleSuggestion]()
        }
        var state = routine
        state.handled = state.handled.filter { now.timeIntervalSince($0.value) < Self.routineMemory }
        let inputs = RoutineInputs(memory: memory, commitments: commitments, suggestions: suggestions, skills: skills)
        // The learning loop (#289): kinds the owner usually accepts come first; ones they keep refusing rest.
        let approvals = state.approvals
        let candidates = MorningRoutine.candidates(inputs, now: now, calendar: calendar)
            .filter { state.handled[$0.id] == nil && !approvals.learnedOff($0.permissionKey, now: now) }
            .enumerated().sorted { lhs, rhs in
                let (left, right) = (approvals.acceptance(lhs.element.permissionKey), approvals.acceptance(rhs.element.permissionKey))
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
        var today = state.today ?? MorningRoutine(day: calendar.startOfDay(for: now))
        today.merge(candidates, approvals: state.approvals, now: now, calendar: calendar)
        state.today = today
        // "Always yes" to a rule applies it now; AegisCore owns the rules.
        for proposal in today.toRun {
            if case .rule = proposal.action {
                applyRule(proposal, in: &state, now: now)
            }
        }
        return saveRoutine(state)
    }

    func decideRoutine(_ ids: [String], approved: Bool, always: Bool) async -> CoreResponse {
        var state = routine
        guard var today = state.today, !ids.isEmpty, ids.count <= MorningRoutine.maxProposals else {
            return .refused(code: "bad_routine")
        }
        let now = clock()
        let chosen = today.proposals.indices.filter { ids.contains(today.proposals[$0].id) && today.proposals[$0].status == .pending }
        guard !chosen.isEmpty else { return .refused(code: "bad_routine") }
        for index in chosen {
            let proposal = today.proposals[index]
            today.proposals[index].status = approved ? .approved : .denied
            if always, proposal.tier.canRemember {
                state.approvals.set(proposal.permissionKey, decision: approved ? .alwaysApprove : .alwaysDeny, approved: approved, now: now)
            } else {
                state.approvals.record(proposal.permissionKey, approved: approved, now: now)
            }
            state.handled[proposal.id] = now
        }
        state.today = today
        for index in chosen {
            let proposal = today.proposals[index]
            guard case let .rule(suggestion) = proposal.action else { continue }
            if approved {
                applyRule(proposal, in: &state, now: now)
            } else {
                // Saying no to a rule also hides the suggestion for 30 days, like dismissing it.
                _ = await ruleSuggestions(dismissing: (suggestion.personID, suggestion.kind))
            }
        }
        return saveRoutine(state)
    }

    func routineDone(_ id: String, succeeded: Bool) -> CoreResponse {
        var state = routine
        guard var today = state.today, let index = today.proposals.firstIndex(where: { $0.id == id && $0.status == .approved })
        else { return .refused(code: "bad_routine") }
        today.proposals[index].status = succeeded ? .executed : .expired
        state.today = today
        return saveRoutine(state)
    }

    private func applyRule(_ proposal: RoutineProposal, in state: inout RoutineState, now: Date) {
        guard case let .rule(suggestion) = proposal.action,
              let index = state.today?.proposals.firstIndex(where: { $0.id == proposal.id })
        else { return }
        let response = suggestion.kind == .vip
            ? priorityResponse(.vip(personID: suggestion.personID, name: suggestion.name))
            : changeMute(suggestion.personID, name: suggestion.name)
        let applied = if case .rules = response {
            true
        } else {
            false
        }
        state.today?.proposals[index].status = applied ? .executed : .expired
        state.handled[proposal.id] = now
    }

    private func saveRoutine(_ state: RoutineState) -> CoreResponse {
        if let routineFile {
            guard (try? routineFile.save(state)) != nil else { return .refused(code: "routine_unwritable") }
        }
        routine = state
        return .morningRoutine(state.today ?? MorningRoutine(day: calendar.startOfDay(for: clock())))
    }
}
