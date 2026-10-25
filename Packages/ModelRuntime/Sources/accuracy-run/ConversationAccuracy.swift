import AegisKit
import AegisStorage
import Foundation
import ModelRuntime

/// The owner-reported conversation failures (#36), using invented data and the real local model.
/// Reports booleans and timings only; never reads personal stores or prints message/answer text.
func conversationAccuracy(modelDirectory: String, output: String) async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 10))!
    let today = calendar.startOfDay(for: now)
    let store = try GRDBEventStore(path: ":memory:")
    let parcel = Event(
        source: .sms, sourceRecordID: "example-chinese-parcel", appID: nil, sender: "Example Store", threadID: "example-parcel",
        eventTime: now.addingTimeInterval(-86400), eventTimeSource: .sent, captureTime: now,
        title: nil, body: "您的包裹已经到达。", content: .complete,
        observations: [.init(route: .chatDB, sourceRecordID: "example-chinese-parcel", captureTime: now)],
        direction: .incoming, senderHandle: "0400000001"
    )
    func occurrence(_ id: String, _ title: String, offset: Int) -> CalendarOccurrence {
        let start = calendar.date(byAdding: .day, value: offset, to: today)!
        return .init(
            itemID: id, occurrenceDate: nil, calendarTitle: nil, title: title, start: start,
            end: calendar.date(byAdding: .day, value: 1, to: start)!, isAllDay: true,
            timeZone: calendar.timeZone.identifier, location: nil, status: .confirmed, captureTime: now
        )
    }
    let visit = occurrence("example-visit", "Example library visit", offset: 0)
    let concert = occurrence("example-concert", "Example concert", offset: -1)
    let holiday = occurrence("example-holiday", "Example holiday", offset: 1)
    try await store.ingest(.init(source: .messages, status: .init(ok: true, code: .ok), events: [parcel], checkpoint: nil))
    try await store.ingest(.init(
        source: .calendar, status: .init(ok: true, code: .ok), events: [], occurrences: [visit, concert, holiday], checkpoint: nil
    ))
    let model = ConversationModel(client: MLXModelClient(folder: URL(fileURLWithPath: modelDirectory)))
    let core = try CoreEngine(
        store: store, collectors: [], model: model, persistence: ConversationSchedule(),
        initial: .init(openingHour: 7, openingMinute: 0, timeZone: calendar.timeZone),
        options: .init(modelName: "synthetic-accuracy"), calendar: calendar, clock: { now }
    )
    var reports: [[String: Any]] = []
    func check(_ name: String, _ question: String, accepts: (Answer) -> Bool) async throws {
        let start = Date()
        let response = await core.handle(.ask(question: question))
        let passed = if case let .answer(answer) = response {
            accepts(answer)
        } else {
            false
        }
        var report: [String: Any] = ["case": name, "passed": passed, "elapsed_s": Date().timeIntervalSince(start)]
        switch response {
        case let .answer(answer):
            report["events"] = answer.eventIDs.count
            report["schedule"] = answer.scheduleIDs.count
            report["mentions_library"] = answer.text.lowercased().contains("library")
            report["mentions_arrived"] = answer.text.lowercased().contains("arrived")
            report["mentions_parcel"] = answer.text.lowercased().contains("parcel") || answer.text.lowercased().contains("package")
        case let .refused(code): report["failure_code"] = code
        default: report["failure_code"] = "unexpected_response"
        }
        reports.append(report)
        try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
        print("Synthetic conversation case \(name): \(passed ? "pass" : "fail")")
    }
    try await check("today-only", "What am I doing today?") {
        $0.scheduleIDs == [visit.id] && $0.text.lowercased().contains("library")
            && !$0.text.lowercased().contains("concert") && !$0.text.lowercased().contains("holiday")
    }
    for (name, question) in [("acknowledgement", "Sweet."), ("social", "How's it going?")] {
        try await check(name, question) {
            !["library", "concert", "holiday", "parcel"].contains(where: $0.text.lowercased().contains)
        }
    }
    try await check("no-result", "Translate the Chinese text message I received today into English") {
        $0.text.contains("couldn't find") && $0.eventIDs.isEmpty
    }
    try await check("clarified-translation", "It was yesterday. From Example Store.") {
        $0.eventIDs == [parcel.id] && $0.text.lowercased().contains("arrived")
            && ($0.text.lowercased().contains("parcel") || $0.text.lowercased().contains("package"))
    }
    try await check(
        "compound-translation",
        "That was yesterday. Also, what was that text message I got in Chinese? Can you translate it?"
    ) {
        $0.eventIDs == [parcel.id] && $0.text.lowercased().contains("arrived")
    }
    try await check("dont-remember", "Don't remember that.") { $0.model == "memory" }
    guard case let .memories(notes) = await core.handle(.memories) else { throw CocoaError(.coderInvalidValue) }
    reports.append(["case": "no-accidental-facts", "passed": notes.isEmpty])
    try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys, .prettyPrinted])
        .write(to: URL(fileURLWithPath: output), options: .atomic)
    print("Synthetic conversation passed \(reports.filter { $0["passed"] as? Bool == true }.count)/\(reports.count)")
}

private actor ConversationModel: ModelClient {
    let client: MLXModelClient
    init(client: MLXModelClient) {
        self.client = client
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        var request = job
        request.deadline = Date().addingTimeInterval(120)
        let result = try await client.run(request)
        if job.id.hasPrefix("ask-"), let text = result.text, let draft = Briefing.extractJSON(text) {
            let events = draft["event_ids"] as? [String] ?? []
            let schedule = draft["schedule_ids"] as? [String] ?? []
            print("Synthetic citation check: event_count=\(events.count), schedule_count=\(schedule.count), "
                + "events_known=\(events.allSatisfy { job.user.contains("[" + $0 + "]") }), "
                + "schedule_known=\(schedule.allSatisfy { job.user.contains("[" + $0 + "]") })")
        }
        return result
    }

    func cancel(jobID: String) async {
        await client.cancel(jobID: jobID)
    }
}

private struct ConversationSchedule: SchedulePersistence {
    func load() throws -> BriefSchedule? {
        nil
    }

    func save(_: BriefSchedule) throws {}
}
