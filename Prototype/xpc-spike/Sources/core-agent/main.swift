import Foundation
import SpikeShared

/// AegisCore stand-in: an SMAppService agent that runs while the app is closed and asks ModelService
/// for jobs over XPC. It runs one scripted sequence, writes the timings to core-result.json, and exits.
struct Outcome: Codable {
    var step: String
    var ok: Bool
    var milliseconds: Int
    var modelPID: Int?
    var error: String?
}

func connect() -> NSXPCConnection {
    let connection = NSXPCConnection(machServiceName: Spike.modelService, options: [])
    connection.setCodeSigningRequirement(Spike.serverRequirement)
    connection.remoteObjectInterface = NSXPCInterface(with: SpikeModelProtocol.self)
    connection.resume()
    return connection
}

/// One job, with a deadline; `killAfter` kills the model mid-job to test interruption.
func run(_ step: String, job: Int, seconds: Double, on connection: NSXPCConnection, killAfter: Double? = nil) -> Outcome {
    let start = Date()
    let done = DispatchSemaphore(value: 0)
    var outcome = Outcome(step: step, ok: false, milliseconds: 0)
    let lock = NSLock()
    func finish(_ update: (inout Outcome) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard outcome.milliseconds == 0 else { return }
        update(&outcome)
        outcome.milliseconds = max(1, Int(Date().timeIntervalSince(start) * 1000))
        done.signal()
    }
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        finish { $0.error = (error as NSError).domain + " \((error as NSError).code)" }
    } as? SpikeModelProtocol
    proxy?.generate(job: job, seconds: seconds) { data, failure in
        let fields = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Int] }
        finish {
            $0.ok = fields != nil
            $0.modelPID = fields?["pid"]
            $0.error = failure
        }
    }
    if let killAfter {
        Thread.sleep(forTimeInterval: killAfter)
        let pids = runningModelPIDs()
        Spike.log("core", "killing model pids \(pids)")
        for pid in pids {
            kill(pid_t(pid), SIGKILL)
        }
    }
    if done.wait(timeout: .now() + 30) == .timedOut {
        finish { $0.error = "timed out after 30 s" }
    }
    Spike.log("core", "\(step): ok=\(outcome.ok) ms=\(outcome.milliseconds) pid=\(outcome.modelPID ?? -1) error=\(outcome.error ?? "-")")
    return outcome
}

/// The model agent's PIDs, from launchd's own listing (no process-table scraping of other apps).
func runningModelPIDs() -> [Int] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["list", Spike.modelID]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return text.split(separator: "\n").compactMap { line in
        guard line.contains("\"PID\"") else { return nil }
        return Int(line.filter(\.isNumber))
    }
}

Spike.log("core", "started (app closed: \(spikeAppInstances()))")
var results: [Outcome] = []
let first = connect()
results.append(run("1 cold start: launchd launches ModelService on demand", job: 1, seconds: 0.2, on: first))
results.append(run("2 warm: same process", job: 2, seconds: 0.2, on: first))
Thread.sleep(forTimeInterval: 8)
results.append(run("3 after idle exit: relaunched on the same connection", job: 3, seconds: 0.2, on: first))
results.append(run("4 killed mid-job: interruption reported", job: 4, seconds: 3, on: first, killAfter: 1))
results.append(run("5 retry after interruption", job: 5, seconds: 0.2, on: first))
first.invalidate()
let second = connect()
results.append(run("6 new connection", job: 6, seconds: 0.2, on: second))
second.invalidate()
Thread.sleep(forTimeInterval: 7)
let modelGone = runningModelPIDs().isEmpty
Spike.log("core", "model process gone after idle: \(modelGone)")
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let summary: [String: AnyEncodable] = ["steps": AnyEncodable(results), "modelGoneAfterIdle": AnyEncodable(modelGone)]
try? encoder.encode(summary).write(to: Spike.folder.appendingPathComponent("core-result.json"))
Spike.log("core", "done")
exit(0)

/// Counts running instances of the spike app (expected 0: the agents run with the app closed).
func spikeAppInstances() -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "AegisXPCSpike"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .split(separator: "\n").count ?? 0
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}
