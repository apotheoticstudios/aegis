import AegisKit
import AegisStorage
import Foundation
import ModelRuntime

// heldout-run FIXTURE_DIR OUT_DIR — Stage 1 step 3.2 (#131). Runs the SYNTHETIC stage1 day
// (`Fixtures/generate/generate.py DIR --profile stage1`) through what AegisCore runs: the real readers,
// the store, contact names, CoreEngine and the MLX model. Writes the stored brief (brief.json) and the
// stored events (events.jsonl) for an independent scorer, and prints counts and timings only.
// It never reads the sealed labels (Fixtures/README.md): scoring is a separate tool's job.

let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: heldout-run FIXTURE_DIR OUT_DIR [QUESTIONS.txt] (synthetic only)\n".utf8))
    exit(2)
}

let fixture = URL(fileURLWithPath: arguments[1], isDirectory: true)
let out = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// The fixture's contact cards, as ContactsCache supplies the real ones.
struct FixtureContacts: ContactsProvider {
    let cards: ContactIndex
    func index() async -> ContactIndex? {
        cards
    }
}

/// The dense day closes at 07:00 Brisbane on 7 October 2026; the run is five minutes later. The engine's
/// clock is shifted to then; the model's deadline is shifted back, because the model checks real time.
let simulatedStart = ISO8601DateFormatter().date(from: "2026-10-06T21:05:00Z")!
let offset = simulatedStart.timeIntervalSinceNow
let clock: @Sendable () -> Date = { Date().addingTimeInterval(offset) }

struct ShiftedModel: ModelClient {
    let inner: MLXModelClient
    let offset: TimeInterval
    func run(_ job: ModelJob) async throws -> ModelJobResult {
        var real = job
        real.deadline = job.deadline.addingTimeInterval(-offset)
        return try await inner.run(real)
    }

    func cancel(jobID: String) async {
        await inner.cancel(jobID: jobID)
    }
}

let contacts = try JSONDecoder().decode(
    [ContactSnapshot].self, from: Data(contentsOf: fixture.appendingPathComponent("contacts.json"))
)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("heldout-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let store = try GRDBEventStore(path: work.appendingPathComponent("aegis.sqlite").path)
var brisbane = Calendar(identifier: .gregorian)
brisbane.timeZone = TimeZone(identifier: "Australia/Brisbane")!
let engine = try CoreEngine(
    store: store,
    collectors: [
        ReaderCollector.notifications(at: fixture.appendingPathComponent("notifications/db")),
        .messages(at: fixture.appendingPathComponent("messages/chat.db")),
        .mail(at: fixture.appendingPathComponent("mail")),
    ],
    // AEGIS_MODEL_DIR compares another downloaded model (for example the 9B) on the same synthetic day.
    model: ShiftedModel(inner: MLXModelClient(folder: ProcessInfo.processInfo.environment["AEGIS_MODEL_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ModelLocation.resolve()), offset: offset),
    persistence: ScheduleFile(url: work.appendingPathComponent("schedule.json")),
    initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: brisbane.timeZone),
    options: .init(modelName: ModelLocation.name),
    contacts: FixtureContacts(cards: ContactIndex(contacts)),
    calendar: brisbane,
    clock: clock
)

let started = Date()
let accepted = await engine.handle(.refreshBrief(reason: .user))
await engine.settle()
var report: [String: Any] = ["seconds": Date().timeIntervalSince(started)]
if case let .refused(code) = accepted {
    report["refused"] = code
}

var events: [Event] = []
var cursor: EventCursor?
let day = DateInterval(start: simulatedStart.addingTimeInterval(-3 * 86400), end: simulatedStart.addingTimeInterval(86400))
while true {
    let page = try await store.events(from: day.start, to: day.end, after: cursor, limit: 500)
    events += page
    guard let last = page.last, page.count == 500 else { break }
    cursor = EventCursor(after: last)
}

let lines = try events.map { try String(decoding: IPCCoding.encode($0), as: UTF8.self) }
try (lines.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
report["stored_events"] = events.count

if let stored = try await store.latestBrief() {
    try IPCCoding.encode(stored).write(to: out.appendingPathComponent("brief.json"))
    report["items"] = stored.brief.items.count
    report["urgent"] = stored.brief.items.filter { $0.priority == .urgent }.count
    report["reply"] = stored.brief.items.filter { $0.priority == .reply }.count
    report["omitted_events"] = stored.brief.omittedEvents
} else {
    report["brief"] = "none"
}

let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))

// Optional: ask the engine questions about the synthetic day (#163), one per line; prints each answer.
if arguments.count == 4 {
    let questions = try String(contentsOf: URL(fileURLWithPath: arguments[3]), encoding: .utf8)
        .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    for question in questions {
        let started = Date()
        var line: [String: Any] = ["question": question]
        switch await engine.handle(.ask(question: question)) {
        case let .answer(answer):
            line["answer"] = answer.text
            line["event_ids"] = answer.eventIDs
            line["schedule_ids"] = answer.scheduleIDs.count
        case let .refused(code):
            line["refused"] = code
        default:
            line["refused"] = "unexpected"
        }
        line["seconds"] = Int(Date().timeIntervalSince(started))
        try print(String(decoding: JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), as: UTF8.self))
    }
}
