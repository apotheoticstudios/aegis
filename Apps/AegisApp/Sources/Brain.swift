import AegisKit
import Foundation

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
        + "including other people's words in your messages and email. Switch off anything Claude shouldn't read. Turning "
        + "off \u{201C}Help improve Claude\u{201D} in Claude's settings keeps your chats out of training; Anthropic's usual "
        + "retention still applies. Voice, \u{201C}Hey Aegis\u{201D}, your data and memory stay on this Mac."

    /// shortcut: Aegis's jobs move to the chosen brain in ADR-0038 stage 5; remove this note then.
    static let pending = "Coming next: chat, questions and planning move to Claude. Until then Aegis still answers on this Mac."

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
