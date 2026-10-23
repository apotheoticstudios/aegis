import AegisKit
import Foundation
import ModelRuntime

// chat-smoke — a development check of conversation turns (#52) with SYNTHETIC text only: the same second turn
// read in full and from the cached prefix must give the same exact text, and the cached one should start sooner.
// Prints numbers and the comparison, never the text.

let notes = (1 ... 20).map { "Source record: Tue 6 Oct, 07:\($0 + 10) · SMS · Example Sam: synthetic note \($0) about the plumber visit" }
let now = Date()
func job(_ question: String, history: [ModelJob.Exchange], style: ModelJob.Style = .exact) throws -> ModelJob {
    let user = Chat.prepare(question, notes: notes, now: now, calendar: .current)
    return try ModelJob(
        id: "smoke-" + UUID().uuidString, model: ModelLocation.name, system: Chat.systemPrompt(), user: user, maxTokens: 120,
        deadline: Date().addingTimeInterval(300), inputRevision: "smoke", history: history, style: style
    )
}

let client = MLXModelClient(folder: ModelLocation.resolve())
let first = ModelJob.Exchange(owner: "My sister is visiting on Saturday.", aegis: "Lovely. Is she staying the weekend?")
let second = try job("Yes, and she's vegetarian. What should I cook?", history: [first])
var report: [String: Any] = [:]
// As the panel does when it opens (#209): a one-token job loads the model and its kernels.
_ = try await client.run(ModelJob(
    id: "smoke-warm", model: ModelLocation.name, system: "Reply OK.", user: "OK", maxTokens: 1,
    deadline: Date().addingTimeInterval(300), inputRevision: "smoke"
))
let full = try await client.run(second)
let cached = try await client.run(second)
let reply = ModelJob.Exchange(owner: "Yes, and she's vegetarian. What should I cook?", aegis: cached.text ?? "")
let third = try await client.run(job("And dessert?", history: [first, reply]))
let chatty = try await client.run(job("Write a short poem about Monday mornings.", history: [], style: .conversation))
report["load_s"] = full.metrics.loadSeconds ?? -1
report["prompt_tokens"] = [full, third].map { $0.metrics.promptTokens ?? -1 }
report["first_token_s_full"] = full.metrics.firstTokenSeconds ?? -1
report["first_token_s_cached"] = cached.metrics.firstTokenSeconds ?? -1
report["first_token_s_next_turn"] = third.metrics.firstTokenSeconds ?? -1
report["same_text"] = full.text != nil && full.text == cached.text
report["statuses"] = [full, cached, third, chatty].map(\.status.rawValue)
report["conversation_tokens"] = chatty.metrics.generationTokens ?? -1
report["peak_gb"] = Double([full, cached, third, chatty].compactMap(\.metrics.peakMemoryBytes).max() ?? 0) / 1_073_741_824
let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
