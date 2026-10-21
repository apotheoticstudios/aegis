import Combine
import Contacts
import EventKit
import ProbeShared
import ServiceManagement
import SwiftUI

/// The app half of the permissions probe (Stage 1, issue #66). It registers the launch agent, asks for
/// Calendar, Reminders and Contacts access, and shows side by side what the app and the agent can access.
@main
struct ProbeApp: App {
    var body: some Scene {
        WindowGroup("Aegis permissions probe") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    private let service = SMAppService.agent(plistName: "dev.aegis.permprobe.agent.plist")
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    @State private var agentStatus = "unknown"
    @State private var app: ProbeReport?
    @State private var agent: ProbeReport?
    @State private var message = ""
    @State private var appBanners: BannerReport?
    @State private var watching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which permissions does Aegis's background agent get from the app?")
                .font(.headline)
            Text(
                "Shows only yes/no answers and counts. Nothing from your calendars, reminders or contacts is read or saved. Steps: README.md."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack {
                Button("1. Register agent") { run { try service.register() } }
                Button("2. Ask for Calendar, Reminders, Contacts") { Task { await requestAccess() } }
                Button("Unregister agent") { run { try service.unregister() } }
            }
            HStack {
                Button(watching ? "Watching banners…" : "3. Watch banners for 60 s (app)") { watchBanners() }
                    .disabled(watching)
                Button("Reset banner counts") { resetBanners() }
            }
            HStack {
                Button("Open Login Items settings") { SMAppService.openSystemSettingsLoginItems() }
                Button("Copy results") { copyResults() }
            }
            Divider()
            LabeledContent("Agent status", value: agentStatus)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("").bold()
                    Text("App").bold()
                    Text("Agent").bold()
                }
                row("Full Disk Access", app?.fullDiskAccess, agent?.fullDiskAccess)
                row(
                    "Calendar",
                    app.map { describe($0.calendarStatus, $0.calendarCount) },
                    agent.map { describe($0.calendarStatus, $0.calendarCount) }
                )
                row(
                    "Reminders",
                    app.map { describe($0.remindersStatus, $0.reminderListCount) },
                    agent.map { describe($0.remindersStatus, $0.reminderListCount) }
                )
                row(
                    "Contacts",
                    app.map { "\($0.contactsStatus), readable: \($0.contactsReadable)" },
                    agent.map { "\($0.contactsStatus), readable: \($0.contactsReadable)" }
                )
                row("Accessibility", app?.accessibility, agent?.accessibility)
                row("Banner events", appBanners.map(summary), agent?.banners.map(summary))
                row("Last check", app?.time, agent?.time)
            }
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(width: 760)
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }

    private func row(_ name: String, _ app: String?, _ agent: String?) -> some View {
        GridRow {
            Text(name)
            Text(app ?? "—")
            Text(agent ?? "no result yet")
        }
    }

    private func summary(_ report: BannerReport) -> String {
        guard report.trusted else { return "not trusted" }
        let total = report.events.values.reduce(0, +)
        let failed = report.registrations.filter { $0.value != "ok" }.count
        return "\(total) events in \(Int(report.secondsWatched)) s; \(failed) registrations failed"
    }

    /// Runs the observer on its own thread (its run loop blocks for 60 s) and shows the counts.
    private func watchBanners() {
        watching = true
        Thread {
            let report = Banners.watch(seconds: 60)
            DispatchQueue.main.async {
                appBanners = report
                watching = false
                message = "Watched 60 s."
            }
        }.start()
    }

    private func resetBanners() {
        appBanners = nil
        if var stored = agent {
            stored.banners = nil
            try? Probe.write(stored, name: "agent-result.json")
        }
        refresh()
    }

    private func describe(_ status: String, _ count: Int?) -> String {
        count.map { "\(status) (\($0) visible)" } ?? status
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            message = ""
        } catch {
            message = "Error: \(error.localizedDescription)"
        }
        refresh()
    }

    private func requestAccess() async {
        let store = EKEventStore()
        do {
            _ = try await store.requestFullAccessToEvents()
            _ = try await store.requestFullAccessToReminders()
            _ = try await CNContactStore().requestAccess(for: .contacts)
            message = ""
        } catch {
            message = "Error: \(error.localizedDescription)"
        }
        refresh()
    }

    private func refresh() {
        agentStatus = switch service.status {
        case .notRegistered: "not registered"
        case .enabled: "enabled (checks every 15 s)"
        case .requiresApproval: "needs approval in System Settings › General › Login Items & Extensions"
        case .notFound: "not found in the app bundle"
        @unknown default: "unknown (\(service.status.rawValue))"
        }
        app = Probe.run(process: "app")
        try? Probe.write(app!, name: "app-result.json")
        agent = (try? Data(contentsOf: Probe.resultFolder.appendingPathComponent("agent-result.json")))
            .flatMap { try? JSONDecoder().decode(ProbeReport.self, from: $0) }
    }

    /// Copies statuses and counts (no personal data) for the owner to paste into issue #66.
    private func copyResults() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var reports = [app, agent].compactMap(\.self)
        if let appBanners, !reports.isEmpty {
            reports[0].banners = appBanners
        }
        let text = reports.compactMap { try? String(data: encoder.encode($0), encoding: .utf8) }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Agent status: \(agentStatus)\n" + text, forType: .string)
        message = "Copied."
    }
}
