import Foundation

/// Apple's Messages app as notifications and chat records name it. Real notification databases store
/// the bundle ID in lower case ("com.apple.mobilesms"), so every comparison ignores case (owner's morning).
enum MessagesApp {
    static let bundleIDs: Set<String> = ["com.apple.mobilesms", "com.apple.ichat"]

    static func contains(_ appID: String?) -> Bool {
        appID.map { bundleIDs.contains($0.lowercased()) } ?? false
    }
}
