import AegisKit
import AegisStorage
import Foundation
import ModelRuntime

/// Fixed invented paraphrases through SQLite, hard filters, meaning retrieval and checked model answers.
/// Reports evidence recall separately from answer correctness; never writes queries, source text or drafts.
func intelligenceAccuracy(modelDirectory: String, output: String, probeOnly: Bool = false, caseLimit: Int = .max) async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 10))!
    let store = try GRDBEventStore(path: ":memory:")
    let topics = [
        ("accommodation charges", "The hotel room costs $148.", "148"),
        ("vehicle servicing", "The car oil change will cost $210.", "210"),
        ("electricity charges", "Your power bill totals $76.", "76"),
        ("dining reservation", "Your table at Example Cafe is booked for six people.", "six"),
        ("shipment collection", "Your package can be picked up at the library.", "library"),
        ("rail ticket fare", "The train journey costs $63.", "63"),
        ("dental visit", "Your tooth check-up is booked for Thursday.", "thursday"),
        ("plane ticket price", "The airfare for your flight is $239.", "239"),
        ("computer repairs", "Replacing the laptop keyboard will cost $195.", "195"),
        ("optical appointment", "Your eye examination is booked for Friday.", "friday"),
    ]
    let events = topics.enumerated().map { index, item in
        Event(
            source: .email,
            sourceRecordID: "example-intelligence-\(index)",
            appID: nil,
            sender: "Example Sender \(index)",
            threadID: "example-thread-\(index)",
            eventTime: now.addingTimeInterval(-Double(60 + index)),
            eventTimeSource: .sent,
            captureTime: now,
            title: "Example record \(index)",
            body: item.1,
            content: .complete,
            observations: [.init(route: .mailStore, sourceRecordID: "example-intelligence-\(index)", captureTime: now)],
            direction: .incoming,
            senderHandle: "sender\(index)@example.com"
        )
    }
    try await store.ingest(.init(source: .mail, status: .init(ok: true, code: .ok), events: events, checkpoint: nil))
    let model = IntelligenceModel(client: MLXModelClient(folder: URL(fileURLWithPath: modelDirectory)))
    let core = try CoreEngine(
        store: store,
        collectors: [],
        model: model,
        persistence: IntelligenceSchedule(),
        initial: .init(openingHour: 7, openingMinute: 0, timeZone: .gmt),
        options: .init(modelName: "synthetic-intelligence"),
        calendar: calendar,
        clock: { now }
    )
    let probeTexts = topics.map { VectorMeaning.queryPrefix + $0.0 } + topics.map(\.1)
    if let vectors = await model.embed(probeTexts), vectors.count == probeTexts.count {
        let probe = topics.indices.map { row in
            topics.indices.map { column in
                zip(vectors[row], vectors[topics.count + column]).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            }
        }
        try JSONSerialization.data(withJSONObject: probe).write(to: URL(fileURLWithPath: output + ".scores"), options: .atomic)
    }
    if probeOnly {
        return
    }
    var reports: [[String: Any]] = []
    let templates = ["What did the email about %@ today say?", "Read my email about %@ today", "What was in my email regarding %@ today?"]
    runCases: for (topicIndex, topic) in topics.enumerated() {
        for (variant, template) in templates.enumerated() {
            if reports.count >= caseLimit {
                break runCases
            }
            let question = template.replacingOccurrences(of: "%@", with: topic.0)
            let baseline = try await Ask.prepare(question: question, now: now, calendar: calendar, store: store, contacts: nil)
            await model.reset()
            let start = Date()
            let result = await core.handle(.ask(question: question))
            let evidence = await model.evidence
            var answerOK = false
            var failure = "none"
            switch result {
            case let .answer(answer):
                let fact = topic.2 == "six" ? answer.text.range(of: #"\b(?:six|6)\b"#, options: .caseInsensitive) != nil
                    : answer.text.lowercased().contains(topic.2)
                answerOK = Set(answer.eventIDs) == [events[topicIndex].id] && fact
            case let .refused(code): failure = code
            default: failure = "unexpected_response"
            }
            await reports.append([
                "kind": "paraphrase", "case": "topic_\(topicIndex)_variant_\(variant)",
                "keyword_recall": baseline.eventIDs.contains(events[topicIndex].id),
                "hybrid_recall": evidence.contains(events[topicIndex].id), "answer_correct": answerOK,
                "evidence_count": evidence.count, "elapsed_s": Date().timeIntervalSince(start),
                "embedding_s": model.embeddingSeconds, "model_first_token_s": model.firstTokenSeconds,
                "peak_model_bytes": model.peakBytes, "failure_code": failure, "draft_checks": model.draftChecks,
                "relevance_checks": model.relevanceChecks,
            ])
            try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys, .prettyPrinted])
                .write(to: URL(fileURLWithPath: output), options: .atomic)
            print("Synthetic intelligence case \(reports.count): answer=\(answerOK)")
        }
    }
    if caseLimit == .max {
        for (index, topic) in ["passport application", "school enrolment"].enumerated() {
            await model.reset()
            let response = await core.handle(.ask(question: "Read my email about " + topic + " today"))
            let safe: Bool = if case let .answer(answer) = response {
                answer.eventIDs.isEmpty && answer.text == Ask.notFound
                    || answer.eventIDs.isEmpty && answer.text.contains("couldn't find matching")
            } else {
                false
            }
            reports.append(["kind": "absent", "case": "absent_\(index)", "answer_correct": safe])
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
    }
    print("Synthetic intelligence: keyword=\(reports.filter { $0["keyword_recall"] as? Bool == true }.count), "
        + "hybrid=\(reports.filter { $0["hybrid_recall"] as? Bool == true }.count), "
        + "answers=\(reports.filter { $0["answer_correct"] as? Bool == true }.count)/\(reports.count)")
}

private actor IntelligenceModel: ModelClient {
    let client: MLXModelClient
    private(set) var evidence: Set<String> = []
    private(set) var embeddingSeconds = 0.0
    private(set) var firstTokenSeconds = 0.0
    private(set) var peakBytes = 0
    private(set) var draftChecks: [String: Int] = [:]
    private(set) var relevanceChecks: [String: Int] = [:]
    init(client: MLXModelClient) {
        self.client = client
    }

    func reset() {
        evidence = []; embeddingSeconds = 0; firstTokenSeconds = 0; peakBytes = 0; draftChecks = [:]; relevanceChecks = [:]
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        if job.id.hasPrefix("ask-") {
            let regex = try NSRegularExpression(pattern: #"\[(ev_[0-9a-f]+)\]"#)
            evidence = Set(regex.matches(in: job.user, range: NSRange(job.user.startIndex..., in: job.user)).compactMap {
                Range($0.range(at: 1), in: job.user).map { String(job.user[$0]) }
            })
        }
        var request = job
        request.deadline = Date().addingTimeInterval(job.id.hasPrefix("relevance-") ? 20 : 120)
        let result = try await client.run(request)
        if job.id.hasPrefix("relevance-") {
            let data = Data((result.text ?? "").utf8)
            let selected = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["matches"] as? [Int]
            relevanceChecks = [
                "completed": result.status == .completed ? 1 : 0,
                "bytes": data.count, "valid_selection": selected == nil ? 0 : 1, "selected": selected?.count ?? 0,
                "fenced": result.text?.contains("```") == true ? 1 : 0,
            ]
        }
        if let text = result.text, let draft = Briefing.extractJSON(text) {
            let events = draft["event_ids"] as? [String] ?? []
            let schedules = draft["schedule_ids"] as? [String] ?? []
            draftChecks = [
                "events": events.count,
                "schedules": schedules.count,
                "unknown_events": events.filter { !evidence.contains($0) }.count,
                "answer_chars": (draft["answer"] as? String ?? "").count,
            ]
        }
        firstTokenSeconds = result.metrics.firstTokenSeconds ?? 0
        peakBytes = max(peakBytes, result.metrics.peakMemoryBytes ?? 0)
        return result
    }

    func embed(_ texts: [String]) async -> [[Float]]? {
        let start = Date()
        let result = await client.embed(texts)
        embeddingSeconds += Date().timeIntervalSince(start)
        return result
    }

    func cancel(jobID: String) async {
        await client.cancel(jobID: jobID)
    }
}

private struct IntelligenceSchedule: SchedulePersistence {
    func load() throws -> BriefSchedule? {
        nil
    }

    func save(_: BriefSchedule) throws {}
}
