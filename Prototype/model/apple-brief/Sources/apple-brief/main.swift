// apple-brief (Stage 0, issue #18): writes a brief with Apple's on-device model (Foundation Models)
// from contract events, and records timings. Run on synthetic events by Claude; on a real day only by
// the owner. The model runs on this Mac; nothing leaves it.
//
//   apple-brief --events events.jsonl --prompt ../prompt.md --out brief.json [--metrics metrics.json]

import AppleBriefCore
import Foundation
import FoundationModels

@Generable
enum DraftPriority {
    case urgent
    case reply
    case fyi
}

@Generable
struct DraftItem {
    @Guide(description: "One short sentence for the owner, using only facts from the events.")
    var text: String
    var priority: DraftPriority
    @Guide(description: "Ids of the events this item is based on, exactly as written in square brackets, like ev_0123456789abcdef.")
    var eventIDs: [String]
}

@Generable
struct Draft {
    @Guide(description: "At most 8 items, most important first.", .maximumCount(8))
    var items: [DraftItem]
}

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else {
        return nil
    }
    return args[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

guard let eventsPath = argument("--events"), let promptPath = argument("--prompt"), let outPath = argument("--out") else {
    fail("usage: apple-brief --events events.jsonl --prompt prompt.md --out brief.json [--metrics metrics.json]")
}

guard case .available = SystemLanguageModel.default.availability else {
    fail("Apple's on-device model isn't available on this Mac (\(SystemLanguageModel.default.availability)).")
}

let events: [Event]
let instructions: String
do {
    events = try Briefing.events(fromJSONLines: String(contentsOfFile: eventsPath, encoding: .utf8))
    instructions = try String(contentsOfFile: promptPath, encoding: .utf8)
} catch {
    fail("Couldn't read the input: \(error)")
}

let input = Briefing.input(for: events)

let clock = ContinuousClock()
let start = clock.now
let session = LanguageModelSession(instructions: instructions)
var firstOutput: Duration?
let draft: Draft
do {
    let stream = session.streamResponse(to: input.text, generating: Draft.self)
    for try await _ in stream where firstOutput == nil {
        firstOutput = clock.now - start
    }
    draft = try await stream.collect().content
} catch {
    fail("The model failed: \(error)")
}

let total = clock.now - start

let times = events.map(\.eventTime).sorted()
let now = ISO8601DateFormatter().string(from: Date())
let brief = BriefRecord(
    generatedAt: now,
    windowStart: argument("--window-start") ?? times.first ?? now,
    windowEnd: argument("--window-end") ?? times.last ?? now,
    model: "apple-foundation-models",
    items: draft.items.prefix(8).map { item in
        let priority = switch item.priority {
        case .urgent: "urgent"
        case .reply: "reply"
        case .fyi: "fyi"
        }
        return BriefItemRecord(text: item.text, priority: priority, eventIDs: item.eventIDs)
    },
    omittedEvents: input.omitted
)

do {
    for path in [outPath] + (argument("--metrics").map { [$0] } ?? []) {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try brief.json().write(to: URL(fileURLWithPath: outPath))
    if let metricsPath = argument("--metrics") {
        let metrics: [String: Any] = [
            "model": "apple-foundation-models",
            "first_output_s": firstOutput.map(seconds) ?? -1,
            "total_s": seconds(total),
            "events_in": input.includedIDs.count,
            "events_omitted": input.omitted,
            "input_characters": input.text.count,
            "items": brief.items.count,
            "note": "The model runs in a macOS system process, so this process's memory is not the model's.",
        ]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: metricsPath))
    }
} catch {
    fail("Couldn't write the output: \(error)")
}

print(String(
    format: "Brief with %d items in %.1f s (first output after %.1f s).",
    brief.items.count,
    seconds(total),
    firstOutput.map(seconds) ?? -1
))
