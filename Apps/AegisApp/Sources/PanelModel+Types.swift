import AegisKit
import Foundation

/// The panel's conversation and task types, and hand-off helpers that need none of its state.
extension PanelModel {
    struct Exchange: Identifiable, Equatable {
        let id = UUID()
        let question: String
        let answer: Answer?
        let failure: String?
        /// A finished task's folder (#235).
        var folder: URL?
    }

    /// A task waiting for the owner's Start, or running (#235).
    struct PlanTask: Equatable {
        let request: CloudHandOff.Request
        let asked: String
        let folder: URL
        let actionID = UUID()
        var started: Date?
    }

    /// Answers from Claude or ChatGPT carry their model's name ("chatgpt-plan" through the owner's plan).
    static func isHandOff(_ answer: Answer) -> Bool {
        guard let model = answer.model else { return false }
        return model.hasPrefix("claude") || model.hasPrefix("gpt") || model.hasPrefix("chatgpt")
    }

    static func actionLog() -> ActionLog? {
        guard let folder = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Aegis", isDirectory: true),
            let file = try? ActionLogFile(url: folder.appendingPathComponent("action-log.json"))
        else { return nil }
        return ActionLog(persistence: file)
    }
}
