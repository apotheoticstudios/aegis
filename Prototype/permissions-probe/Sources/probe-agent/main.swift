import ApplicationServices
import Foundation
import ProbeShared

/// The launch agent half: launchd runs it at load and every 15 seconds. It records what it can access
/// (statuses and counts only) to agent-result.json, which the app shows. When the agent is trusted for
/// Accessibility it also watches for notification banners for 12 s and adds the counts to earlier runs
/// (Stage 2 probe 0.1; roles only, never text).
var report = Probe.run(process: "agent")
if AXIsProcessTrusted() {
    let previous = (try? Data(contentsOf: Probe.resultFolder.appendingPathComponent("agent-result.json")))
        .flatMap { try? JSONDecoder().decode(ProbeReport.self, from: $0) }?.banners
    report.banners = Banners.accumulate(Banners.watch(seconds: 12), onto: previous)
}

do {
    try Probe.write(report, name: "agent-result.json")
} catch {
    FileHandle.standardError.write(Data("probe-agent: could not write result\n".utf8))
    exit(1)
}
