import AegisKit
import Foundation
import Observation

/// What Aegis thinks with (ADR-0038): its own models on this Mac, or Claude through the owner's Claude plan. One at
/// a time, kept on the Mac; switching back to this Mac takes effect at once.
enum Brain: String, CaseIterable, Sendable {
    case local, claude

    private static let key = "brain"

    static var current: Brain {
        get { UserDefaults.aegis.string(forKey: key).flatMap(Brain.init(rawValue:)) ?? .local }
        set { UserDefaults.aegis.set(newValue.rawValue, forKey: key) }
    }

    /// What leaves the Mac with Claude chosen, in plain words (ADR-0038 §7).
    static let leaves = "Your requests, and what Aegis reads to answer them, go to Anthropic under your Claude account, "
        + "including other people's words in your messages and email and the memory notes Claude reads. Switch off anything "
        + "Claude shouldn't read. Turning off \u{201C}Help improve Claude\u{201D} in Claude's settings keeps your chats out of "
        + "training; Anthropic's usual retention still applies. If your account has usage credits on, use past your plan's "
        + "limits can be billed. Voice and \u{201C}Hey Aegis\u{201D} stay on this Mac, and your data and memory are stored "
        + "only here."

    private static let localModelKey = "brainLocalModel"

    /// The local model for this brain (#174): with Claude, the small one as the offline fallback; on this Mac, the one
    /// it had before Claude was chosen (the tune-up's), else the one its memory runs.
    static func model(for brain: Brain, before: ModelChoice?, memory: UInt64) -> ModelChoice {
        brain == .claude ? .small : before ?? .forMemory(memory)
    }

    /// Fetches the brain's local model, then records it for AegisCore and ModelService's next start, as the tune-up
    /// does, so nothing ever points at a missing model. Never in tests: no downloads, nothing written to the Mac.
    /// shortcut: a fetch already running (setup's) makes this one return early without recording; switching again,
    /// or the next setup run, records it.
    @MainActor static func followModel(_ brain: Brain) {
        guard !WorldSidecar.isTestHost, let folder = ModelChoice.aegisFolder else { return }
        let current = ModelChoice.current
        if brain == .claude, current != .small {
            UserDefaults.aegis.set(current.name, forKey: localModelKey)
        }
        let before = [ModelChoice.small, .medium].first { $0.name == UserDefaults.aegis.string(forKey: localModelKey) }
        let model = model(for: brain, before: before, memory: ProcessInfo.processInfo.physicalMemory)
        guard model != current else { return }
        Task {
            guard await ModelDownloads.shared.fetch([model.files, .meaning]) else { return }
            try? model.choose(in: folder)
        }
    }

    /// The sign-in check's result for the owner; nil when all is well.
    static func status(_ ending: ClaudeCodeRunner.Ending) -> String? {
        switch ending {
        case .ready: nil
        case .outcome(.signedOut): "Claude Code isn't signed in. Run claude auth login in Terminal once, then check again."
        case .outcome(.refused): "Claude Code has settings or add-ons turned on that Aegis doesn't allow, so it won't be used."
        case .unavailable: "Claude Code isn't installed on this Mac."
        default: "Claude Code didn't answer the check. Try again in a moment."
        }
    }
}

/// The brain, Claude's model and effort, and what Claude may read: one copy for the setup wizard and the Claude and
/// ChatGPT window, so neither shows a stale choice or overwrites the other's. Each change is kept on the Mac at once.
@MainActor @Observable
final class BrainSettings {
    static let shared = BrainSettings()

    var brain = Brain.current {
        didSet {
            Brain.current = brain
            // A running Claude job ends at once, and what it was told so far is forgotten.
            PanelModel.revokeBrain(forget: true)
            if brain != oldValue {
                Brain.followModel(brain)
            }
        }
    }

    var choice = ClaudeCodeRunner.choice {
        didSet { ClaudeCodeRunner.choice = choice }
    }

    var reads = ClaudeReads.enabled {
        didSet {
            ClaudeReads.enabled = reads
            if !oldValue.isSubset(of: reads) {
                PanelModel.revokeBrain(forget: true)
            }
        }
    }

    private(set) var models = ClaudeCodeRunner.models
    /// What's wrong with Claude Code, or "Checking…"; nil after a check that passed, or before any check.
    private(set) var status: String?
    /// A check has finished; with `status` nil, it passed.
    private(set) var checked = false
    let installed: Bool

    init(installed: Bool = ClaudeCodeRunner.executable != nil) {
        self.installed = installed
    }

    /// Asks Claude Code who's signed in and which models the plan offers, without sending anything to Claude.
    func check() {
        guard installed else {
            status = Brain.status(.unavailable)
            checked = true
            return
        }
        status = "Checking Claude Code\u{2026}"
        checked = false
        Task {
            let ending = await ClaudeCodeRunner().check()
            models = ClaudeCodeRunner.models
            status = Brain.status(ending)
            checked = true
        }
    }
}

extension ClaudeTools.Category {
    /// The name on the owner's switch.
    var label: String {
        switch self {
        case .messages: "Messages"
        case .mail: "Mail"
        case .notifications: "Notifications"
        case .calendar: "Calendar and reminders"
        case .memory: "Memory"
        case .health: "Source health"
        }
    }
}
