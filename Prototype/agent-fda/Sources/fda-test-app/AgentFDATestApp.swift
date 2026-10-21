import Combine
import ServiceManagement
import SwiftUI

/// The app half of the Full Disk Access check (Stage 0, issue #11). It registers its bundled launch
/// agent with SMAppService and shows what the agent last reported: whether it could open a folder
/// that macOS protects with Full Disk Access (without reading anything in it).
@main
struct AgentFDATestApp: App {
    var body: some Scene {
        WindowGroup("Aegis agent FDA test") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    private let service = SMAppService.agent(plistName: "dev.aegis.fdatest.agent.plist")
    private let resultFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AegisAgentFDATest/agent-result.json")
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    @State private var agentStatus = "unknown"
    @State private var agentResult = "no result yet"
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Can a background agent open a Full Disk Access–protected folder when only this app has Full Disk Access?")
                .font(.headline)
            Text("The agent only opens and closes macOS's privacy-permissions folder; it reads nothing. See README.md for the steps.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Register agent") { run { try service.register() } }
                Button("Unregister agent") { run { try service.unregister() } }
                Button("Open Login Items settings") { SMAppService.openSystemSettingsLoginItems() }
            }
            Divider()
            LabeledContent("Agent status", value: agentStatus)
            LabeledContent("Agent's last result", value: agentResult)
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
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

    private func refresh() {
        agentStatus = switch service.status {
        case .notRegistered: "not registered"
        case .enabled: "enabled (running every 15 s)"
        case .requiresApproval: "needs approval in System Settings › General › Login Items"
        case .notFound: "not found in the app bundle"
        @unknown default: "unknown (\(service.status.rawValue))"
        }
        guard
            let data = try? Data(contentsOf: resultFile),
            let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            agentResult = "no result yet"
            return
        }
        let readable = switch fields["readable"] {
        case "yes": "ALLOWED"
        case "invalid": "TEST INVALID (protected folder missing; tell Claude)"
        default: "NOT allowed"
        }
        let detail = fields["error"].map { " — \($0)" } ?? ""
        let launchedBy = fields["parent_pid"] == "1" ? "launchd" : "pid \(fields["parent_pid"] ?? "?")"
        agentResult = "\(readable)\(detail) (at \(fields["time"] ?? "?"), started by \(launchedBy))"
    }
}
