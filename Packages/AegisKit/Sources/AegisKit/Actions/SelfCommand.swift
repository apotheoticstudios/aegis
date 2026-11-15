import Foundation

/// Requests about Aegis's own windows (#203): "open the panel", "close the panel", "open your settings". They get a
/// fixed answer; the model never narrates them.
public enum SelfCommand: Sendable, Equatable {
    case openPanel, closePanel, openSettings

    /// `name` is Aegis's current name (the owner can change it), for "open Aegis settings" and "Aegis, open the panel".
    public static func parse(_ text: String, name: String) -> SelfCommand? {
        let me = "(?:aegis|" + NSRegularExpression.escapedPattern(for: name.lowercased()) + ")"
        let line = ActionCommand.cleaned(text).lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"^(?:(?:hey|ok|okay)\s+)?"# + me + #"[,!.:]?\s+"#, with: "", options: .regularExpression)
        func says(_ pattern: String) -> Bool {
            line.range(of: "^" + pattern + "$", options: .regularExpression) != nil
        }
        let panel = #"(?:the |your |my |"# + me + #"(?:'s)? )?(?:panel|hud|dashboard|chat window|main window)"#
        if says(#"(?:open|show|show me|bring up|pull up|launch) (?:up )?"# + panel) {
            return .openPanel
        }
        if says(#"(?:close|hide|dismiss|put away|minimi[sz]e) "# + panel) {
            return .closePanel
        }
        let mine = #"(?:your|"# + me + #"(?:'s)?|the "# + me + ")"
        if says(#"(?:open|show|show me|bring up|pull up|go to) "# + mine + #" (?:settings|preferences)(?: window)?"#) {
            return .openSettings
        }
        return nil
    }
}
