@testable import AegisKit
import XCTest

final class CloudHandOffTests: XCTestCase {
    private let both = CloudHandOff.Availability(providers: [.claude, .chatgpt], automatic: true)
    private let names: Set<String> = ["Example Alex", "Robin Example"]

    func testNamingAProviderHandsTheQuestionOver() {
        XCTAssertEqual(
            CloudHandOff.decide("Ask Claude to explain how vaccines work", history: [], available: both, names: names),
            .cloud(.init(provider: .claude, question: "explain how vaccines work", history: []))
        )
        XCTAssertEqual(
            CloudHandOff.decide("Hey Aegis, ask ChatGPT: write a haiku about rain", history: [], available: both, names: names),
            .cloud(.init(provider: .chatgpt, question: "write a haiku about rain", history: []))
        )
        let onlyClaude = CloudHandOff.Availability(providers: [.claude], automatic: false)
        guard case .unavailable = CloudHandOff.decide("ask chatgpt why the sky is blue", history: [], available: onlyClaude, names: names)
        else {
            return XCTFail("no ChatGPT key: say how to add one")
        }
    }

    func testPersonalQuestionsStayOnTheMac() {
        for line in [
            "ask Claude what my messages say about Saturday", "ask Claude to summarise my emails",
            "ask Claude what Example Alex wants", "ask Claude about Robin", "ask Claude who texted me",
            "ask Claude to write to someone@example.com", "ask Claude to call +61 400 000 123",
            "ask Claude what's on today", "ask Claude to check my calendar for tomorrow",
            "ask Claude what my doctor said", "ask Claude how to get to 12 Example Street",
            "ask Claude what to do, I have a lump on my neck", "ask Claude to prep me for the interview tomorrow at 10",
            "ask Claude if 'Example2020' is a good password", "ask Claude to check BSB 062-000 account 12345678",
            "ask ChatGPT how much tax I owe if I earn 85000",
            "ask Claude to draft a reply to the landlord about the leaking tap", "ask Claude why the doctor changed the medication",
            "ask Claude what to say to the school about the assessment", "ask Claude to explain the diagnosis in this letter",
            "ask Claude to summarise the email thread about the account", "ask Claude how I get out of debt",
            "ask Claude what to do about the lump on my arm", "ask Claude to compare schools for a 6-year-old",
            "ask Claude to plan a birthday party on 12/10", "ask Claude how to appeal a parking fine",
            "ask Claude to write an email to support about a refund", "ask Claude to draft a resignation letter for a job at example.com",
            "ask Claude what robin meant", "ask Claude about alex's birthday",
            "ask Claude I live in Example Town, where should I move",
            "ask Claude I work for example.com, should I resign",
            "ask Claude my name is Example Taylor, write an introduction",
            "ask Claude I am Example Taylor, write an introduction",
            "ask Claude I was born on 3 March 1990, how old am I",
            "ask Claude I'm 35 years old, what insurance should I get",
            "ask Claude I take insulin, can I fast",
            "ask Claude I tested positive for diabetes, what now",
            "ask Claude I have asthma, can I run a marathon",
            "ask Claude I'm at Example Cafe, suggest a nearby walk",
            "ask Claude I weigh 82 kg, am I overweight",
            "ask Claude how to invest my income", "ask Claude explain my medical history",
            "ask Claude draft a reply for my client",
            "ask Claude my password is ExampleSecret, is it strong",
            "ask Claude is ExampleSecret a strong password",
            "ask Claude the API key is ExampleToken, how do I use it",
            "ask Claude to summarise ~/Documents/example.txt",
            "ask Claude to call +61\t400\t000\t123",
        ] {
            guard case let .keep(question, note) = CloudHandOff.decide(line, history: [], available: both, names: names) else {
                return XCTFail(line)
            }
            XCTAssertFalse(question.lowercased().hasPrefix("ask"), line)
            XCTAssertTrue(note.contains("kept it on your Mac"), line)
        }
    }

    func testGeneralQuestionsAreNotPersonal() {
        for line in [
            "explain how vaccines work", "write a python function that reverses a list", "compare the economy 1990-2000",
            "why does my code not compile", "what's the difference between a virus and bacteria",
            "explain how insulin works", "what does a positive diabetes test mean",
            "explain how asthma inhalers work",
            "how do I calculate income tax", "how do I store an API key securely",
            "how does password hashing work", "compare living in two cities",
            "convert 82 kg to pounds", "write an introduction for a fictional character",
            "explain alexandrite formation", // A contact's name substring must not match another word.
        ] {
            XCTAssertFalse(CloudHandOff.isPersonal(line, names: names), line)
        }
    }

    func testAutomaticHandOffOnlyForComplexGeneralQuestions() {
        XCTAssertEqual(
            CloudHandOff.automatic("Explain quantum entanglement in detail", available: both, names: names)?.provider, .claude
        )
        XCTAssertNil(CloudHandOff.automatic("What's up?", available: both, names: names), "small talk")
        XCTAssertNil(CloudHandOff.automatic("How tall is Everest", available: both, names: names), "a quick fact")
        XCTAssertNil(CloudHandOff.automatic("Explain what Example Alex meant", available: both, names: names), "a contact")
        XCTAssertNil(CloudHandOff.automatic("Remember that I like detailed explanations", available: both, names: names))
        let manual = CloudHandOff.Availability(providers: [.claude], automatic: false)
        XCTAssertNil(CloudHandOff.automatic("Explain quantum entanglement in detail", available: manual, names: names))
    }

    func testFollowUpsStayWithTheProviderAndCarryOnlyHandedOffTurns() {
        let history = [
            Chat.Turn(owner: "What's on today?", aegis: "Example stand-up at 9."),
            Chat.Turn(owner: "explain black holes", aegis: "A black hole is…", via: .claude),
        ]
        XCTAssertEqual(
            CloudHandOff.decide("make it shorter", history: history, available: both, names: names),
            .cloud(.init(
                provider: .claude,
                question: "make it shorter",
                history: [.init(owner: "explain black holes", reply: "A black hole is…")]
            ))
        )
        XCTAssertEqual(CloudHandOff.decide("what's on my calendar?", history: history, available: both, names: names), .local)
        // A reply that repeats a personal detail ("your landlord") isn't sent again.
        let personalReply = [Chat.Turn(owner: "draft a polite note", aegis: "Here's a note to your landlord about the tap.", via: .claude)]
        XCTAssertEqual(
            CloudHandOff.decide("make it shorter", history: personalReply, available: both, names: names),
            .cloud(.init(provider: .claude, question: "make it shorter", history: []))
        )
        XCTAssertEqual(CloudHandOff.decide("thanks", history: history, available: both, names: names), .local)
    }

    func testTheSpokenOpeningLeavesOutCodeAndDetail() {
        let reply = "Use reversed(). It returns an iterator. Here's how:\n```python\nlist(reversed(x))\n```\nMore detail follows. And more."
        XCTAssertEqual(CloudHandOff.spoken(reply), "Use reversed(). It returns an iterator. The rest is in the panel.")
        XCTAssertEqual(CloudHandOff.spoken("Paris."), "Paris.")
    }

    func testChangingProvidersDoesNotCarryTheOtherConversation() {
        let history = [Chat.Turn(owner: "explain tides", aegis: "Tides are…", via: .claude)]
        XCTAssertEqual(
            CloudHandOff.decide("ask ChatGPT explain gravity", history: history, available: both, names: names),
            .cloud(.init(provider: .chatgpt, question: "explain gravity", history: []))
        )
    }

    func testTheEngineHandsOffAndKeepsTheReplyForFollowUps() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = RecordingModel()
        let core = try CoreEngine(
            store: MemoryStore(), collectors: [], model: model,
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))),
            options: .init(modelName: "synthetic-model")
        )
        let response = await core.handle(.converse(question: "Ask Claude to explain black holes", cloud: both))
        XCTAssertEqual(response, .handOff(.init(provider: .claude, question: "explain black holes", history: [])))
        _ = await core.handle(.handedOff(question: "explain black holes", reply: "A black hole is…", provider: .claude))
        let followUp = await core.handle(.converse(question: "make it shorter", cloud: both))
        XCTAssertEqual(
            followUp,
            .handOff(.init(
                provider: .claude,
                question: "make it shorter",
                history: [.init(owner: "explain black holes", reply: "A black hole is…")]
            ))
        )
        // Without a key, naming Claude explains how to add one; nothing is handed off.
        guard case let .answer(answer) = await core.handle(.ask(question: "ask Claude about black holes")) else {
            return XCTFail("expected an answer")
        }
        XCTAssertTrue(answer.text.contains("API key"))
        XCTAssertNil(model.lastInput, "none of this needed the local model")
    }

    func testExpandedMemoryNeverLeavesTheMac() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = try CoreEngine(
            store: MemoryStore(), collectors: [], model: RecordingModel(),
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: .gmt),
            options: .init(modelName: "synthetic-model")
        )
        _ = await core.handle(.ask(question: "When I say physics, explain quantum entanglement in detail"))
        for question in ["physics", "Do that again"] {
            let response = await core.handle(.converse(question: question, cloud: both))
            if case .handOff = response {
                XCTFail("Stored words left the Mac: \(question)")
            }
        }
        _ = await core.handle(.ask(question: "When I say clouds, ask Claude explain black holes"))
        let response = await core.handle(.converse(question: "clouds", cloud: both))
        if case .handOff = response {
            XCTFail("A named provider in a shortcut must also stay local")
        }
    }

    func testHandOffContractsRoundTrip() throws {
        let requests: [CoreRequest] = [
            .converse(question: "explain black holes", cloud: both),
            .handedOff(question: "explain black holes", reply: "A black hole is…", provider: .chatgpt),
        ]
        for request in requests {
            XCTAssertEqual(try IPCCoding.decode(CoreRequest.self, from: IPCCoding.encode(request)), request)
        }
        let response = CoreResponse.handOff(.init(provider: .claude, question: "q", history: [.init(owner: "a", reply: "b")]))
        XCTAssertEqual(try IPCCoding.decode(CoreResponse.self, from: IPCCoding.encode(response)), response)
    }
}

final class PlanHandOffTests: XCTestCase {
    func testTasksAreRequestsToMakeFiles() {
        let both = CloudHandOff.Availability(providers: [.chatgpt], automatic: false)
        guard case let .cloud(task) = CloudHandOff.decide(
            "Get ChatGPT to make a spreadsheet comparing three laptops under $2000", history: [], available: both, names: []
        ) else { return XCTFail("expected a hand-off") }
        XCTAssertEqual(task.work, .task)
        guard case let .cloud(answer) = CloudHandOff.decide("Ask ChatGPT why the sky is blue", history: [], available: both, names: [])
        else {
            return XCTFail("expected a hand-off")
        }
        XCTAssertEqual(answer.work, .answer)
        XCTAssertFalse(CloudHandOff.isTask("write a haiku about rain"), "short writing is answered in the conversation")
        XCTAssertTrue(CloudHandOff.isTask("write a cover letter for a barista job"))
    }

    func testThePlanPromptHoldsOnlyInstructionsTurnsAndTheOwnersWords() {
        let request = CloudHandOff.Request(
            provider: .chatgpt, question: "make it shorter", history: [.init(owner: "explain tides", reply: "Tides are…")]
        )
        let prompt = CloudHandOff.planPrompt(request)
        XCTAssertTrue(prompt.hasPrefix(CloudHandOff.instructions))
        XCTAssertTrue(prompt.contains("don't run commands"))
        XCTAssertTrue(prompt.hasSuffix("Owner: explain tides\nYou: Tides are…\n\nOwner: make it shorter"))
        let task = CloudHandOff.Request(provider: .chatgpt, question: "make a packing list", history: [], work: .task)
        XCTAssertTrue(CloudHandOff.planPrompt(task).hasPrefix(CloudHandOff.taskInstructions))
    }

    func testTaskFoldersAreNamedByDateAndRequest() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 17, minute: 5)))
        XCTAssertEqual(
            CloudHandOff.folderName(for: "make a spreadsheet comparing three laptops under $2000", now: now, calendar: calendar),
            "2026-10-12 1705 spreadsheet comparing three laptops"
        )
        XCTAssertEqual(CloudHandOff.folderName(for: "make me a", now: now, calendar: calendar), "2026-10-12 1705 task")
    }
}
