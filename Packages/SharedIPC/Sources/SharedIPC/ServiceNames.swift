import Foundation

/// launchd labels, Mach service names and signing identifiers for Aegis's processes (ADR-0013).
/// The label, the Mach service and the signing identifier of each agent are the same string.
public enum ServiceNames {
    /// The app's bundle and signing identifier.
    public static let app = "dev.aegis.app"
    /// AegisCore: always on; the app reaches it through this Mach service.
    public static let core = "dev.aegis.core"
    /// ModelService: started by launchd only when AegisCore connects; exits by itself.
    public static let model = "dev.aegis.model"

    /// The agents' plists inside `Aegis.app/Contents/Library/LaunchAgents`.
    public static let corePlist = "dev.aegis.core.plist"
    public static let modelPlist = "dev.aegis.model.plist"
}
