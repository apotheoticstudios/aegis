import Foundation

/// Where macOS keeps the stores AegisCore reads (macOS 15 and later). AegisCore opens them read-only,
/// with the Full Disk Access the user gives Aegis in setup (ADR-0010); nothing else in Aegis does.
enum SourcePaths {
    private static let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")

    /// Notification Center's database.
    static let notifications = library
        .appendingPathComponent("Group Containers/group.com.apple.usernoted/db2/db") // privacy-guard: allow-real-path AegisCore collector, read-only with the user's grant
    /// Messages (iMessage and SMS).
    static let messages = library
        .appendingPathComponent("Messages/chat.db") // privacy-guard: allow-real-path AegisCore collector, read-only with the user's grant
    /// Apple Mail's folder; the reader finds the newest version's Envelope Index.
    static let mail = library
        .appendingPathComponent("Mail") // privacy-guard: allow-real-path AegisCore collector, read-only with the user's grant
}
