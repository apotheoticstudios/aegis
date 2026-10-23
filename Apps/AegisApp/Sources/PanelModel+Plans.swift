import AegisKit
import Foundation

/// One step of a plan (#47): an action already judged by the policy, or a message that still asks on its own card.
struct PlanStep {
    var command: ActionCommand?
    var request: ActionRequest?
    var guessed = false
    /// The owner's words for a message step.
    var message: String?
    /// What the card says for this step: "open Safari".
    let said: String
}

/// Several requests at once (#47, owner's choice): each is worked out and judged first, then one card lists them,
/// and one yes runs them in order.
extension PanelModel {
    /// The plan card for several requests in one line, or nil for a single request.
    func planAnswer(_ question: String, origin: ActionOrigin) async -> Answer? {
        guard let parts = CommandPlan.parts(question, now: Date(), calendar: .current) else { return nil }
        var steps: [PlanStep] = []
        var left: [String] = []
        for part in parts {
            if ActionCommand.parse(part, now: Date(), calendar: .current) == nil, let message = MessageCommand.parse(part) {
                let who = (message.channel == .email ? "email " : "text ") + (message.candidates.first?.name ?? "them")
                steps.append(PlanStep(message: part, said: who))
                continue
            }
            guard let (command, guessed) = await resolve(part) else {
                left.append("“\(part)”")
                continue
            }
            let request = ActionRequest(payload: command.payload, origin: origin)
            guard await log(request, .proposed, guessed: guessed).allowed else {
                await log(request, .rejected, guessed: guessed)
                left.append("“\(part)”")
                continue
            }
            let said = command.summary(calendar: .current).replacingOccurrences(of: #"\?$"#, with: "", options: .regularExpression)
            steps.append(PlanStep(
                command: command,
                request: request,
                guessed: guessed,
                said: said.prefix(1).lowercased() + said.dropFirst()
            ))
        }
        let skipped = left.isEmpty ? "" : " I'll leave out " + left.joined(separator: " and ") + ": I can't do that."
        guard let first = steps.compactMap(\.request).first else {
            // Only messages: each asks on its own card anyway.
            return await Self.said(steps.isEmpty ? "I can't do any of that." : runPlan(steps) + skipped)
        }
        for step in steps {
            if let request = step.request {
                await log(request, .awaitingConfirmation, guessed: step.guessed)
            }
        }
        let text = "Here's the plan: " + steps.map(\.said).joined(separator: ", then ") + "."
        ActionPresence.shared.pending = PendingAction(command: nil, request: first, text: text, at: Date(), plan: steps)
        return Self.said(text + skipped + " Say yes, or press Go.")
    }

    /// Runs approved steps in order. A message stops the plan at its own card; the rest runs once that's answered.
    func runPlan(_ steps: [PlanStep]) async -> String {
        var said: [String] = []
        for (index, step) in steps.enumerated() {
            guard let command = step.command, let request = step.request else {
                await said.append(messageAnswer(step.message ?? "", origin: .ownerTyped)?.text ?? "I couldn't work out that message.")
                if ActionPresence.shared.pending != nil {
                    let rest = Array(steps.dropFirst(index + 1))
                    ActionPresence.shared.planRest = rest.isEmpty ? nil : rest
                    break
                }
                continue
            }
            let (worked, text) = await execute(command)
            await log(request, worked ? .succeeded : .failed, guessed: step.guessed)
            said.append(text)
        }
        return said.joined(separator: " ")
    }

    /// The rest of a plan, once the message card it stopped at is answered.
    func resumePlan() async -> String {
        guard ActionPresence.shared.pending == nil, let rest = ActionPresence.shared.planRest else { return "" }
        ActionPresence.shared.planRest = nil
        return await runPlan(rest)
    }

    /// A part's command with its app, shortcut or file found, and whether the local model picked it; nil if it
    /// can't be done. The same order as one request: fixed phrases first, then the model.
    private func resolve(_ part: String) async -> (ActionCommand, Bool)? {
        if let command = ActionCommand.parse(part, now: Date(), calendar: .current), let settled = await settle(command) {
            return (settled, false)
        }
        guard CommandPlan.looksLikeCommand(part) else { return nil }
        let shortcuts = await Self.shortcutNames()
        guard case let .commandPlan(step?) = await service.handle(.commandPlan(question: part, shortcuts: shortcuts)),
              let settled = await settle(step.command)
        else { return nil }
        return (settled, true)
    }

    /// An app by name, else a shortcut, else a file; a shortcut or file by what the owner called it.
    private func settle(_ command: ActionCommand) async -> ActionCommand? {
        switch command {
        case let .openApp(name):
            if Self.application(named: name) != nil {
                return command
            }
            if let shortcut = await Self.shortcut(named: name) {
                return .runShortcut(name: shortcut)
            }
            return await Self.found(name, reveal: false)
        case let .runShortcut(name):
            return await Self.shortcut(named: name).map { .runShortcut(name: $0) }
        case let .findFile(name, reveal):
            return await Self.found(name, reveal: reveal)
        case .moveLast, .removeLast:
            return nil
        default:
            return command
        }
    }
}
