import AegisKit
import AegisStorage
import Foundation
import ModelRuntime

/// Fixed invented regressions through real SQLite, retrieval, answer checks and the local model.
func retrievalAccuracy(modelDirectory: String, output: String) async throws {
    let now = Date(timeIntervalSince1970: 1_792_400_400) // Monday 2026-10-19 09:00 UTC
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let store = try GRDBEventStore(path: ":memory:")
    func event(_ id: String, source: Event.Source, sender: String, body: String, title: String? = nil, age: Double) -> Event {
        let handle = source == .imessage ? "alex@example.com" : "updates@" + sender.lowercased().replacingOccurrences(of: " ", with: "") + ".invalid"
        return Event(
            source: source, sourceRecordID: id, appID: source == .email ? "com.apple.mail" : "com.apple.MobileSMS",
            sender: sender, threadID: id, eventTime: now.addingTimeInterval(-age), eventTimeSource: .sent,
            captureTime: now, title: title, body: body, content: .complete,
            observations: [.init(route: source == .email ? .mailStore : .chatDB, sourceRecordID: id, captureTime: now)],
            senderHandle: handle
        )
    }
    let invoice = event(
        "example-labs-invoice", source: .email, sender: "ExampleLabs",
        body: String(repeating: "This is invented introductory text. ", count: 20) + "Invoice 1043 totals $148 and is due Friday.",
        title: "Invoice 1043", age: 3600
    )
    let parcel = event(
        "example-parcel", source: .email, sender: "Example Parcel",
        body: "Your invented parcel is ready to collect at the library.", title: "Parcel ready", age: 1800
    )
    let message = event(
        "example-alex-folder", source: .imessage, sender: "Alex Example",
        body: "The blue folder is on the library shelf.", age: 1200
    )
    try await store.ingest(CollectionBatch(
        source: .messages, status: .init(ok: true, code: .ok), events: [invoice, parcel, message], checkpoint: nil
    ))
    let client = AccuracyModel(client: MLXModelClient(folder: URL(fileURLWithPath: modelDirectory)))
    let core = try CoreEngine(
        store: store, collectors: [], model: client, persistence: AccuracySchedule(),
        initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: .gmt), options: .init(modelName: "accuracy-candidate"),
        contacts: AccuracyContacts(), calendar: calendar, clock: { now }
    )
    let cases: [(String, String, [String], [String])] = [
        ("today-mail", "What emails did I get today?", [invoice.id, parcel.id], ["invoice", "parcel"]),
        ("spoken-sender", "What did the email from Example Labs today say?", [invoice.id], ["148"]),
        ("polite-read", "Tell me what Alex said today", [message.id], ["blue", "library"]),
        ("late-evidence", "What was the amount for invoice 1043 today?", [invoice.id], ["148"]),
        ("current-weekday", "What did Alex say Monday?", [message.id], ["blue", "library"]),
    ]
    var reports: [[String: Any]] = []
    for (name, question, ids, words) in cases {
        let start = Date()
        let response = await core.handle(.ask(question: question))
        if case let .answer(answer) = response {
            let passed = Set(answer.eventIDs) == Set(ids) && words.allSatisfy(answer.text.lowercased().contains)
            reports.append([
                "case": name, "passed": passed, "synthetic_answer": answer.text, "event_ids": answer.eventIDs,
                "elapsed_s": Date().timeIntervalSince(start),
            ])
            print("Synthetic retrieval case \(name): \(passed ? "pass" : "fail")")
        } else {
            let draft = await client.lastDraft
            reports.append([
                "case": name, "passed": false, "response": String(describing: response),
                "synthetic_draft": draft ?? "",
            ])
            print("Synthetic retrieval case \(name): fail")
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
    }
    print("Synthetic retrieval passed \(reports.filter { $0["passed"] as? Bool == true }.count)/\(cases.count)")
}

private struct AccuracyContacts: ContactsProvider {
    func index() async -> ContactIndex? {
        ContactIndex([ContactSnapshot(id: "example-alex", displayName: "Alex Example", emails: ["alex@example.com"])])
    }
}

private struct AccuracySchedule: SchedulePersistence {
    func load() throws -> BriefSchedule? {
        nil
    }

    func save(_: BriefSchedule) throws {}
}

/// Fixtures keep a fixed civil date; model timeouts must still use the real wall clock on later runs.
private actor AccuracyModel: ModelClient {
    let client: MLXModelClient
    private(set) var lastDraft: String?

    init(client: MLXModelClient) {
        self.client = client
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        var request = job
        request.deadline = Date().addingTimeInterval(120)
        let result = try await client.run(request)
        lastDraft = result.text
        return result
    }

    func cancel(jobID: String) async {
        await client.cancel(jobID: jobID)
    }
}
