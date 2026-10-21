import AppKit
import OSLog

/// Keeps Apple Mail running, hidden and without taking focus, so new email reaches its store and the brief
/// (ADR-0008). Does nothing while Mail is running, and never quits it.
@MainActor
final class MailKeeper {
    static let bundleID = "com.apple.mail"
    private var launching = false
    private let isRunning: () -> Bool
    private let applicationURL: () -> URL?
    private let launch: (URL, NSWorkspace.OpenConfiguration) async throws -> Void

    init(
        isRunning: @escaping () -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty },
        applicationURL: @escaping () -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) },
        launch: @escaping (URL, NSWorkspace.OpenConfiguration) async throws -> Void = { url, configuration in
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    ) {
        self.isRunning = isRunning
        self.applicationURL = applicationURL
        self.launch = launch
    }

    func ensureRunning() async {
        guard !launching, !isRunning(), let url = applicationURL() else { return }
        launching = true
        defer { launching = false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        do {
            try await launch(url, configuration)
        } catch {
            Logger(subsystem: "dev.aegis.core", category: "mail-keeper")
                .notice("mail background launch failed: \((error as NSError).code)")
        }
    }
}
