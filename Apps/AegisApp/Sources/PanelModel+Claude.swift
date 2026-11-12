import AegisKit
import Foundation

/// Claude's actions (ADR-0038 stage 3, pure C): each is the same typed command the owner's words would make, found
/// the same way, judged by the same policy at the same tier, shown on the same cards and written to the same action
/// log, as Claude's request. Nothing here approves a card: only the owner's Add, Go, Send or "yes" does.
extension PanelModel {
    func claude(_ action: ClaudeTools.Action) async -> String {
        // A card the owner hasn't answered stays: anything that would need a card waits for them.
        if !ActionPresence.shared.claudeMayAsk, Self.asks(action) {
            return Self.cardWaiting
        }
        switch action {
        case let .command(command):
            return await claudeCommand(command)
        case let .message(to, text, channel):
            return await messageCard(MessageCommand(channel: channel, to: to, text: text), words: nil, origin: .claude).text
        case let .plan(commands):
            return await claudePlan(commands)
        }
    }

    private func claudeCommand(_ command: ActionCommand) async -> String {
        if case let .openApp(name) = command {
            guard let app = Self.application(named: name) else { return "There's no app called “\(name)” on this Mac." }
            return await openApp(app, name: name, origin: .claude)
        }
        guard let found = await claudeFind(command) else { return Self.missing(command) }
        return await perform(found, origin: .claude)
    }

    /// Several actions on one card (#47): each found and judged first; one approval runs them in order.
    private func claudePlan(_ commands: [ActionCommand]) async -> String {
        var steps: [PlanStep] = []
        var left: [String] = []
        for command in commands {
            guard let found = await claudeFind(command) else {
                left.append(Self.missing(command))
                continue
            }
            let request = ActionRequest(payload: found.payload, origin: .claude)
            guard await log(request, .proposed).allowed else {
                await log(request, .rejected)
                left.append("Aegis can't “\(found.summary(calendar: .current).dropLast())”.")
                continue
            }
            let said = found.summary(calendar: .current).replacingOccurrences(of: #"\?$"#, with: "", options: .regularExpression)
            steps.append(PlanStep(command: found, request: request, said: said.prefix(1).lowercased() + said.dropFirst()))
        }
        guard let first = steps.compactMap(\.request).first else {
            return (["None of that is something Aegis can do."] + left).joined(separator: " ")
        }
        for step in steps {
            if let request = step.request {
                await log(request, .awaitingConfirmation)
            }
        }
        let text = "Here's the plan: " + steps.map(\.said).joined(separator: ", then ") + "."
        guard ActionPresence.shared.install(PendingAction(command: nil, request: first, text: text, at: Date(), plan: steps)) else {
            await cancel(steps)
            return Self.cardWaiting
        }
        return ([text] + left + ["Say yes, or press Go."]).joined(separator: " ")
    }

    /// The command with what it names found on this Mac: an app that exists, a shortcut by its exact name, a file
    /// in the home folder. Nil when there's no such thing.
    private func claudeFind(_ command: ActionCommand) async -> ActionCommand? {
        switch command {
        case let .openApp(name):
            Self.application(named: name) == nil ? nil : command
        case let .runShortcut(name):
            await Self.shortcut(named: name).map(ActionCommand.runShortcut)
        case let .findFile(name, reveal):
            await Self.found(name, reveal: reveal)
        default:
            command
        }
    }

    /// Whether the action shows a card (anything but an automatic step).
    private static func asks(_ action: ClaudeTools.Action) -> Bool {
        switch action {
        case .message, .plan: true
        case let .command(command): [.reminder, .calendar].contains(command.payload.domain)
        }
    }

    private static func missing(_ command: ActionCommand) -> String {
        switch command {
        case let .openApp(name): "There's no app called “\(name)” on this Mac."
        case let .runShortcut(name): "The owner has no shortcut called “\(name)”."
        case let .findFile(name, _): "There's nothing called “\(name)” in the owner's home folder."
        default: "Aegis couldn't find that."
        }
    }
}

/// Claude's tools with the Claude brain chosen: reads from AegisCore, actions through the panel.
struct ClaudeBrainTools: ClaudeToolSource {
    let model: PanelModel
    let reads: ClaudeReads
    /// The job still has the owner's authority: not replaced, stopped or closed, and Claude still chosen.
    let live: @Sendable @MainActor () -> Bool

    func fetch(_ call: ClaudeTools.Call, enabled: Set<ClaudeTools.Category>) async -> ClaudeTools.Payload {
        guard await live() else { return .refused("Stopped.") }
        guard case let .act(action) = call else { return await reads.fetch(call, enabled: enabled) }
        let said = await model.claude(action)
        return ClaudeTools.Payload(text: said, counts: [:], isError: false)
    }
}
