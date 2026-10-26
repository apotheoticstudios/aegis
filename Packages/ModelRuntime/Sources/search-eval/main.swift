import AegisKit
import Foundation
import ModelRuntime

// search-eval — ADR-0032's check of the model's search plans: SYNTHETIC questions in many wordings, today fixed on a
// Wednesday, each plan scored against what it must look up. Prints each question with pass or fail, then the score.

struct Case {
    let question: String
    let lookup: Bool
    /// At least one of these places must be searched.
    var places: Set<SearchPlan.Place> = []
    /// Acceptable spans of days; empty means any (or none).
    var days: [ClosedRange<Int>] = []
    var topic: String?
}

let cases: [Case] = [
    Case(question: "What have I got on for the next week?", lookup: true, places: [.calendar], days: [0 ... 11]),
    Case(question: "What's on tomorrow?", lookup: true, places: [.calendar], days: [1 ... 1]),
    Case(question: "Am I free on Friday?", lookup: true, places: [.calendar], days: [2 ... 2]),
    Case(question: "Do I have anything next Monday?", lookup: true, places: [.calendar], days: [5 ... 5]),
    Case(question: "What's my schedule like next week?", lookup: true, places: [.calendar], days: [0 ... 11]),
    Case(question: "Anything on this weekend?", lookup: true, places: [.calendar], days: [3 ... 4]),
    Case(question: "When's my dentist appointment?", lookup: true, places: [.calendar], topic: "dentist"),
    Case(question: "Am I busy tonight?", lookup: true, places: [.calendar], days: [0 ... 0]),
    Case(question: "What reminders are due today?", lookup: true, places: [.calendar], days: [0 ... 0]),
    Case(
        question: "What's happening over the next few days?",
        lookup: true,
        places: [.calendar],
        days: [0 ... 2, 0 ... 3, 0 ... 4, 1 ... 3, 1 ... 4]
    ),
    Case(question: "Have I got plans for Saturday night?", lookup: true, places: [.calendar], days: [3 ... 3]),
    Case(question: "What's coming up in the next fortnight?", lookup: true, places: [.calendar], days: [0 ... 13, 0 ... 14]),
    Case(question: "Am I double booked anywhere tomorrow?", lookup: true, places: [.calendar], days: [1 ... 1]),
    Case(question: "Do I need to be anywhere at 3pm?", lookup: true, places: [.calendar], days: [0 ... 0]),
    Case(question: "What's on my plate this week?", lookup: true, places: [.calendar], days: [-2 ... 4, 0 ... 4, 0 ... 6]),
    Case(question: "What time is my flight on Thursday?", lookup: true, places: [.calendar, .mail], days: [1 ... 1]),
    Case(question: "Any meetings clash next week?", lookup: true, places: [.calendar], days: [0 ... 11]),
    Case(question: "Am I swamped over the coming seven days?", lookup: true, places: [.calendar], days: [0 ... 11]),
    Case(question: "Got much on Thursday arvo?", lookup: true, places: [.calendar], days: [1 ... 1]),
    Case(question: "What did Sam say yesterday?", lookup: true, places: [.messages, .mail], days: [-1 ... -1]),
    Case(question: "Did anyone email me about the invoice?", lookup: true, places: [.mail], topic: "invoice"),
    Case(question: "What texts did I get today?", lookup: true, places: [.messages], days: [0 ... 0]),
    Case(question: "What did I send Robin last night?", lookup: true, places: [.messages, .mail], days: [-1 ... -1, -1 ... 0]),
    Case(question: "Has the parcel arrived?", lookup: true, places: [.messages, .mail], topic: "parcel"),
    Case(question: "Did my mum message me this morning?", lookup: true, places: [.messages], days: [0 ... 0]),
    Case(question: "What did I miss while I was out?", lookup: true, places: [.messages, .mail]),
    Case(question: "Any emails from work this week?", lookup: true, places: [.mail], days: [-2 ... 4, -2 ... 0, 0 ... 4, -3 ... 0]),
    Case(question: "Did the plumber reply?", lookup: true, places: [.messages, .mail]),
    Case(question: "Can you summarise my emails from yesterday?", lookup: true, places: [.mail], days: [-1 ... -1]),
    Case(question: "What did Robin ask me for?", lookup: true, places: [.messages, .mail]),
    Case(question: "What did I agree to do for Sam?", lookup: true, places: [.messages, .mail]),
    Case(question: "Is there anything urgent I should know about?", lookup: true, places: [.messages, .mail]),
    Case(question: "When is Sam's birthday party?", lookup: true, places: [.calendar, .messages]),
    Case(question: "Tell me a joke", lookup: false),
    Case(question: "How do I make pancakes?", lookup: false),
    Case(question: "Who is the prime minister of Australia?", lookup: false),
    Case(question: "Write a short poem about autumn", lookup: false),
    Case(question: "What should I cook for dinner tonight?", lookup: false),
    Case(question: "Explain how a heat pump works", lookup: false),
    Case(question: "What's a good name for a cat?", lookup: false),
]

/// Held out: wordings never used while writing the prompt, scored on their own.
let heldOut: [Case] = [
    Case(question: "Is my diary clear on Sunday?", lookup: true, places: [.calendar], days: [4 ... 4]),
    Case(question: "Whats on the cards for tmrw?", lookup: true, places: [.calendar], days: [1 ... 1]),
    Case(question: "Have I got anything booked in the next couple of days?", lookup: true, places: [.calendar], days: [0 ... 2, 0 ... 3]),
    Case(question: "Do I have to be somewhere this arvo?", lookup: true, places: [.calendar], days: [0 ... 0]),
    Case(question: "What's left on my to-do list for today?", lookup: true, places: [.calendar], days: [0 ... 0]),
    Case(question: "Any appointments I should remember this month?", lookup: true, places: [.calendar]),
    Case(question: "Did I ever hear back from the bank?", lookup: true, places: [.messages, .mail]),
    Case(question: "Who messaged me while I was asleep?", lookup: true, places: [.messages]),
    Case(question: "What was that address Jordan sent me?", lookup: true, places: [.messages, .mail]),
    Case(question: "Any news on the job application?", lookup: true, places: [.mail, .messages]),
    Case(question: "Did I reply to Priya on Monday?", lookup: true, places: [.messages, .mail], days: [-2 ... -2]),
    Case(question: "Has anyone asked me something I haven't answered?", lookup: true, places: [.messages, .mail]),
    Case(question: "What did the school email about last week?", lookup: true, places: [.mail], days: [-9 ... -3, -9 ... 0]),
    Case(question: "When's the car due for its service?", lookup: true, places: [.calendar, .mail]),
    Case(question: "What's the capital of Canada?", lookup: false),
    Case(question: "Give me three ideas for a birthday present", lookup: false),
    Case(question: "How long should I boil an egg?", lookup: false),
    Case(question: "Translate good morning into French", lookup: false),
    Case(question: "What's the difference between a virus and bacteria?", lookup: false),
    Case(question: "Recommend a good sci-fi book", lookup: false),
]

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = .current
calendar.firstWeekday = 2
let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 15))! // a Wednesday afternoon
let client = MLXModelClient(folder: ModelLocation.resolve())
var passed = 0
var heldPassed = 0
var seconds: [Double] = []
for (index, item) in (cases + heldOut).enumerated() {
    let held = index >= cases.count
    let job = ModelJob(
        id: "plan-" + UUID().uuidString, model: ModelLocation.name, system: SearchPlan.systemPrompt(),
        user: SearchPlan.input(question: item.question, now: now, calendar: calendar), maxTokens: 120,
        deadline: Date().addingTimeInterval(120), inputRevision: "eval"
    )
    let started = Date()
    let result = try await client.run(job)
    seconds.append(Date().timeIntervalSince(started))
    let plan = result.text.flatMap { SearchPlan.parse($0, question: item.question) }
    var problems: [String] = []
    if let plan {
        if plan.lookup != item.lookup {
            problems.append("lookup \(plan.lookup)")
        }
        if item.lookup, !item.places.isEmpty, plan.places.isDisjoint(with: item.places) {
            problems.append("places \(plan.places.map(\.rawValue).sorted())")
        }
        // The days the plan's time covers, counted from today.
        let span = plan.window(now: now, calendar: calendar).map { window -> ClosedRange<Int> in
            let today = calendar.startOfDay(for: now)
            let first = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: window.start)).day ?? 0
            let last = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: window.end.addingTimeInterval(-1)))
                .day ?? 0
            return first ... last
        }
        if item.lookup, !item.days.isEmpty, !item.days.contains(where: { $0 == span }) {
            problems.append("when \(plan.when ?? "none") → \(span.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "none")")
        }
        if let topic = item.topic, !plan.topics.contains(where: { $0.lowercased().contains(topic) }) {
            problems.append("topics \(plan.topics)")
        }
    } else {
        problems.append("no usable plan")
    }
    if problems.isEmpty {
        if held {
            heldPassed += 1
        } else {
            passed += 1
        }
    }
    print((problems.isEmpty ? "PASS  " : "FAIL  ") + (held ? "[held out] " : "") + item
        .question + (problems.isEmpty ? "" : "  — " + problems.joined(separator: ", ")))
}

let sorted = seconds.sorted()
print("HELD OUT \(heldPassed)/\(heldOut.count)")
print(
    "SCORE \(passed)/\(cases.count) · median \(String(format: "%.2f", sorted[sorted.count / 2])) s · slowest \(String(format: "%.2f", sorted.last ?? 0)) s"
)
