import AegisKit
import Foundation
import ModelRuntime

/// Fixed invented cases only. No personal stores, network, or caller-supplied message data.
/// accuracy-run MODEL_DIRECTORY OUTPUT_JSON
let args = CommandLine.arguments
guard (3 ... 4).contains(args.count) else { exit(2) }
if args.count == 4, args[3] == "retrieval" {
    try await retrievalAccuracy(modelDirectory: args[1], output: args[2])
    exit(0)
}

let cases: [(String, String, String)] = [
    (
        "sender-mention",
        "Who asked me to call Sam?",
        "[ev_000000000001] SMS · Alex Example asked you: \"Can you call Sam Sample about the invoice?\""
    ),
    (
        "question-not-fact",
        "Has the parcel arrived?",
        "[ev_000000000002] SMS · Robin Example asked you: \"Did the parcel arrive?\""
    ),
    (
        "separate-events",
        "Are the dinner and the invoice related?",
        "[ev_000000000003] SMS · Alex Example · conversation=one: \"Dinner on Friday at six.\"\n"
            + "[ev_000000000004] Email · Sam Sample · conversation=two: \"The invoice is due Friday.\""
    ),
    (
        "negated-attendance",
        "Is Robin coming to dinner?",
        "[ev_000000000005] SMS · Alex Example wrote: \"Robin Example cannot come to dinner. I will bring the cake.\""
    ),
    (
        "calendar-invite",
        "Who is confirmed for the meeting?",
        "[cal_000000000006] Team meeting · status=confirmed · listed invitees (attendance unconfirmed): \"Alex Example, Sam Sample\""
    ),
    (
        "first-person",
        "Who will collect the parcel?",
        "[ev_000000000007] SMS · Alex Example · incoming: \"I will collect the parcel. You do not need to.\""
    ),
    (
        "same-name",
        "Did Alex change the venue?",
        "[ev_000000000008] SMS · Alex Example · sender_id=one · conversation=one: \"Meet at the library.\"\n"
            + "[ev_000000000009] Email · Alex Example · sender_id=two · conversation=two: \"Meet at the museum.\""
    ),
]
let client = MLXModelClient(folder: URL(fileURLWithPath: args[1]))
var reports: [[String: Any]] = []
for (name, question, context) in cases where args.count == 3 {
    let job = ModelJob(
        id: name, model: "accuracy-candidate", system: Ask.systemPrompt(),
        user: "Question: \(question)\nContext:\n\(context)", maxTokens: 300,
        deadline: Date().addingTimeInterval(180), inputRevision: name
    )
    let result = try await client.run(job)
    reports.append([
        "case": name, "status": result.status.rawValue, "synthetic_answer": result.text ?? "",
        "load_s": result.metrics.loadSeconds ?? 0, "first_token_s": result.metrics.firstTokenSeconds ?? 0,
        "generate_s": result.metrics.generateSeconds ?? 0,
        "peak_bytes": result.metrics.peakMemoryBytes ?? 0,
    ])
    let data = try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys, .prettyPrinted])
    try data.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
    print("Completed synthetic case: \(name), status: \(result.status.rawValue)")
}

let briefInput = cases.map(\.2).filter { !$0.contains("[cal_") }.joined(separator: "\n")
let briefJob = try ModelJob(
    id: "brief", model: "accuracy-candidate", system: Briefing.systemPrompt(), user: "Events:\n" + briefInput,
    maxTokens: 800, deadline: Date().addingTimeInterval(180), inputRevision: "brief"
)
let brief = try await client.run(briefJob)
reports.append([
    "case": "brief", "status": brief.status.rawValue, "synthetic_answer": brief.text ?? "",
    "load_s": brief.metrics.loadSeconds ?? 0, "first_token_s": brief.metrics.firstTokenSeconds ?? 0,
    "generate_s": brief.metrics.generateSeconds ?? 0, "peak_bytes": brief.metrics.peakMemoryBytes ?? 0,
])
try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys, .prettyPrinted])
    .write(to: URL(fileURLWithPath: args[2]), options: .atomic)
print("Completed synthetic brief: \(brief.status.rawValue)")
