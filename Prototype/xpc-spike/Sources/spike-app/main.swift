import Foundation
import ServiceManagement
import SpikeShared

/// The app half: registers or unregisters the two launch agents with SMAppService, prints their status,
/// then exits, so everything after registration runs with the app closed.
let core = SMAppService.agent(plistName: "dev.aegis.xpcsigned.core.plist")
let model = SMAppService.agent(plistName: "dev.aegis.xpcsigned.model.plist")

func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown(\(status.rawValue))"
    }
}

let command = CommandLine.arguments.dropFirst().first ?? "status"
do {
    switch command {
    case "register":
        // Model first: Core connects to it as soon as Core starts.
        try model.register()
        try core.register()
    case "unregister":
        try core.unregister()
        try model.unregister()
    default:
        break
    }
} catch {
    print("error: \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)")
}

print("model: \(describe(model.status))")
print("core: \(describe(core.status))")
Spike.log("app", "\(command): model=\(describe(model.status)) core=\(describe(core.status))")
