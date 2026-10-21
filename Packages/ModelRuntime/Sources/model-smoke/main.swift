import AegisKit
import Foundation
import ModelRuntime

// model-smoke EVENTS.jsonl — a development check of the MLX client with SYNTHETIC events only
// (Prototype/contracts/examples/events.jsonl). Builds the brief input exactly as AegisCore does, runs it
// through MLXModelClient, checks the draft with BriefChecks, and prints numbers and the check result.

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: model-smoke EVENTS.jsonl (synthetic only)\n".utf8))
    exit(2)
}

let lines = try String(contentsOf: URL(fileURLWithPath: arguments[1]), encoding: .utf8).split(separator: "\n")
let events = try lines.map { try JSONDecoder().decode(Event.self, from: Data($0.utf8)) }
let start = events.map(\.eventTime).min() ?? Date()
let end = (events.map(\.eventTime).max() ?? Date()).addingTimeInterval(1)
let input = try BriefInputPolicy(windowStart: start, windowEnd: end).build(events)
let job = try ModelJob(
    id: "smoke-1", model: ModelLocation.name, system: Briefing.systemPrompt(), user: input.text,
    maxTokens: ModelJob.maxOutputTokens, deadline: Date().addingTimeInterval(300), inputRevision: "smoke"
)
let client = MLXModelClient(folder: ModelLocation.resolve())
let result = try await client.run(job)
var report: [String: Any] = ["status": result.status.rawValue, "failure": result.failure?.rawValue ?? "-"]
let metrics = result.metrics
report["load_s"] = metrics.loadSeconds ?? -1
report["first_token_s"] = metrics.firstTokenSeconds ?? -1
report["generate_s"] = metrics.generateSeconds ?? -1
report["prompt_tokens"] = metrics.promptTokens ?? -1
report["generation_tokens"] = metrics.generationTokens ?? -1
report["peak_gb"] = Double(metrics.peakMemoryBytes ?? 0) / 1_073_741_824
if let text = result.text, let answer = Briefing.extractJSON(text) {
    let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    switch BriefChecks.check(answer, input: input, events: byID, windowStart: start, windowEnd: end, model: ModelLocation.name) {
    case let .success(checked):
        report["checks"] = "passed"
        report["items"] = checked.brief.items.count
        report["urgent"] = checked.brief.items.filter { $0.priority == .urgent }.count
        report["dropped"] = checked.droppedItems
    case let .failure(rejection):
        report["checks"] = "rejected: \(rejection.rawValue)"
    }
} else {
    report["checks"] = "no JSON draft"
}

let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
