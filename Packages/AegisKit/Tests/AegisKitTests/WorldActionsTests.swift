@testable import AegisKit
import Foundation
import XCTest

/// Synthetic requests and model replies only.
final class WorldActionsTests: XCTestCase {
    func testCatalogueLoadsAllAllowedNamesWithinBudget() {
        XCTAssertFalse(WorldActions.catalogue.isEmpty)
        XCTAssertLessThan(WorldActions.catalogue.utf8.count, 9000)
        XCTAssertEqual(WorldActions.names.count, 30)
        XCTAssertTrue(WorldActions.names.contains("next_satellite_pass"))
        XCTAssertTrue(WorldActions.names.contains("adjust_camera_zoom"))
        // Every layer, cameras included, is the owner's to use (#311).
        XCTAssertTrue(WorldActions.names.contains("control_cctv"))
        XCTAssertTrue(WorldActions.catalogue.contains("alpr-cameras"))
    }

    func testPromptAndInputContainOnlyTheRequestAndOptionalPlace() {
        XCTAssertTrue(WorldActions.systemPrompt().hasSuffix(WorldActions.catalogue))
        XCTAssertTrue(WorldActions.systemPrompt().contains("ONLY JSON"))
        XCTAssertEqual(WorldActions.input(question: "Show Tokyo", place: nil), "OWNER SAYS: Show Tokyo")
        XCTAssertEqual(
            WorldActions.input(question: "Show flights there", place: "Tokyo"),
            "OWNER SAYS: Show flights there\nTHE GLOBE IS SHOWING: Tokyo"
        )
    }

    func testFencedJSONWithProseKeepsArgumentsOrderAndSpeech() throws {
        let reply = """
        Here is a plan:
        ```json
        {"actions":[{"name":"fly_to_location","arguments":{"query":"Tokyo"}},
        {"name":"set_layer_visibility","arguments":{"layerId":"flights","enabled":true}}],"say":"Showing Tokyo."}
        ```
        """
        let plan = try XCTUnwrap(WorldActions.parse(reply))
        XCTAssertEqual(plan.actions, [
            WorldAction(name: "fly_to_location", arguments: .object(["query": .string("Tokyo")])),
            WorldAction(name: "set_layer_visibility", arguments: .object(["layerId": .string("flights"), "enabled": .bool(true)])),
        ])
        XCTAssertEqual(plan.say, "Showing Tokyo.")
    }

    func testUnknownNamesAreDroppedAndCCTVControlIsKept() throws {
        let plan = try XCTUnwrap(WorldActions.parse("""
        {"actions":[{"name":"unknown_action","arguments":{}},
        {"name":"control_cctv","arguments":{"action":"enable"}},
        {"name":"zoom_to_globe","arguments":{}}]}
        """))
        XCTAssertEqual(plan.actions.map(\.name), ["control_cctv", "zoom_to_globe"])
    }

    func testCameraLayersAndPanelsAreKeptIncludingNestedArrays() throws {
        let arguments: [WorldValue] = [
            .object(["layerId": .string("cctv"), "enabled": .bool(true)]),
            .object(["layerId": .string("ALPR-cameras")]),
            .object(["targetLayer": .string("license-plate-readers")]),
            .object(["panelId": .string("cctv-panel"), "open": .bool(true)]),
            .object(["layers": .array([.string("flights"), .string("Traffic-Cameras")])]),
            .object(["nested": .array([.object(["layerId": .string("webcamera")])])]),
        ]
        for value in arguments {
            let reply = try encodedPlan([WorldAction(name: "analyst_query", arguments: value)])
            XCTAssertEqual(WorldActions.parse(reply)?.actions.count, 1)
        }
    }

    func testOwnerReferencesAreDroppedInAnyStringArgument() throws {
        for text in ["my house", "MINE", "our street", "near me", "Home", "house"] {
            let action = WorldAction(name: "annotate_map", arguments: .object([
                "annotations": .array([.object(["type": .string("pin"), "target": .string(text)])]),
            ]))
            XCTAssertEqual(try WorldActions.parse(encodedPlan([action]))?.actions, [])
        }
    }

    func testPublicNamesCoordinatesAndViewpointMovementRemainAllowed() throws {
        let actions = [
            WorldAction(name: "fly_to_location", arguments: .object(["query": .string("Minehead")])),
            WorldAction(name: "fly_to_location", arguments: .object(["latitude": .number(35), "longitude": .number(139)])),
            WorldAction(name: "move_camera", arguments: .object(["motion": .string("orbit")])),
            WorldAction(name: "analyst_query", arguments: .object(["layers": .array([.string("flights")])])),
        ]
        XCTAssertEqual(try WorldActions.parse(encodedPlan(actions))?.actions, actions)
    }

    func testCapAppliesAfterFilteringAndPreservesOrder() throws {
        let names = ["unknown", "zoom_to_globe", "stop_tracking", "clear_annotations", "get_current_view_state", "fly_route"]
        let actions = names.map { WorldAction(name: $0, arguments: .object([:])) }
        XCTAssertEqual(try WorldActions.parse(encodedPlan(actions))?.actions, Array(actions.dropFirst().prefix(4)))
    }

    func testInvalidJSONOrShapeReturnsNil() {
        for reply in [
            "not JSON", "{", "{}", #"{"actions":null}"#, #"{"actions":{}}"#,
            #"{"actions":[{"name":"zoom_to_globe"}]}"#,
            #"{"actions":[{"name":"zoom_to_globe","arguments":[]}]}"#,
            #"{"actions":[],"say":12}"#,
        ] {
            XCTAssertNil(WorldActions.parse(reply))
        }
    }

    func testEmptyAndFullyFilteredPlansAreValid() throws {
        let empty = try XCTUnwrap(WorldActions.parse(#"{"actions":[]}"#))
        XCTAssertTrue(empty.actions.isEmpty)
        XCTAssertNil(empty.say)
        let filtered = try XCTUnwrap(WorldActions.parse(#"{"actions":[{"name":"unknown","arguments":{}}]}"#))
        XCTAssertEqual(filtered, empty)
    }

    func testWireContractsRoundTrip() throws {
        let request = CoreRequest.worldPlan(question: "Show Tokyo")
        let response = CoreResponse.worldPlan(
            actions: [WorldAction(name: "fly_to_location", arguments: .object(["query": .string("Tokyo")]))], say: "Showing Tokyo."
        )
        XCTAssertEqual(try IPCCoding.decode(CoreRequest.self, from: IPCCoding.encode(request)), request)
        XCTAssertEqual(try IPCCoding.decode(CoreResponse.self, from: IPCCoding.encode(response)), response)
    }

    private func encodedPlan(_ actions: [WorldAction]) throws -> String {
        let data = try JSONEncoder().encode(["actions": actions])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

final class WorldActionsEngineTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-world-" + UUID().uuidString)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testRouteRunsOneBoundedJobWithoutReadingOrWritingConversationMemory() async throws {
        let model = WorldPlanModel(text: #"{"actions":[{"name":"zoom_to_globe","arguments":{}}],"say":"The whole globe."}"#)
        let core = try engine(model)
        let memory = MemoryBook(exchanges: [PastExchange(at: now, owner: "Synthetic earlier question", aegis: "Earlier reply.")])
        await core.seedWorldTestMemory(memory)
        let response = await core.handle(.worldPlan(question: " Show the whole globe "))
        XCTAssertEqual(response, .worldPlan(
            actions: [WorldAction(name: "zoom_to_globe", arguments: .object([:]))], say: "The whole globe."
        ))
        let jobs = await model.jobs
        XCTAssertEqual(jobs.count, 1)
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(job.model, "synthetic-model")
        XCTAssertEqual(job.system, WorldActions.systemPrompt())
        XCTAssertEqual(job.user, WorldActions.input(question: "Show the whole globe", place: nil))
        XCTAssertEqual(job.maxTokens, 300)
        XCTAssertEqual(job.deadline, now.addingTimeInterval(60))
        XCTAssertEqual(job.inputRevision, SHA256.hex(Array(job.user.utf8)))
        XCTAssertTrue(job.validate().isEmpty)
        let after = await core.memory
        let conversation = await core.conversation
        let learning = await core.learnQueue
        XCTAssertEqual(after, memory)
        XCTAssertTrue(conversation.isEmpty)
        XCTAssertTrue(learning.isEmpty)
    }

    func testBadQuestionsRefuseWithoutModelJobs() async throws {
        let model = WorldPlanModel()
        let core = try engine(model)
        let empty = await core.handle(.worldPlan(question: " \n "))
        let oversized = await core.handle(.worldPlan(question: String(repeating: "x", count: CoreRequest.maxQuestionScalars + 1)))
        XCTAssertEqual(empty, .refused(code: "bad_question"))
        XCTAssertEqual(oversized, .refused(code: "too_long"))
        let jobs = await model.jobs
        XCTAssertTrue(jobs.isEmpty)
    }

    func testInvalidPlanAndModelStatusesRefuse() async throws {
        for status in ModelJobResult.Status.allCases {
            let core = try engine(WorldPlanModel(text: "not a plan", status: status))
            let response = await core.handle(.worldPlan(question: "Show Tokyo"))
            XCTAssertEqual(response, .refused(code: status == .completed ? "invalid_plan" : status.rawValue))
        }
        let core = try engine(WorldPlanModel(throwsError: true))
        let response = await core.handle(.worldPlan(question: "Show Tokyo"))
        XCTAssertEqual(response, .refused(code: "unavailable"))
    }

    func testEmptyPlanReturnsEmptyActions() async throws {
        let core = try engine(WorldPlanModel())
        let response = await core.handle(.worldPlan(question: "Tell a synthetic joke"))
        XCTAssertEqual(response, .worldPlan(actions: [], say: nil))
    }

    func testNewOwnerQuestionCancelsWorldPlan() async throws {
        let model = HeldModel()
        let core = try engine(model)
        let world = Task { await core.handle(.worldPlan(question: "Show Tokyo")) }
        await model.waitUntilRunning()
        _ = await core.handle(.ask(question: "What is 2 + 2?"))
        let response = await world.value
        XCTAssertTrue(model.wasCancelled)
        XCTAssertEqual(response, .refused(code: "cancelled"))
        let memory = await core.memory
        XCTAssertFalse(memory.exchanges.contains { $0.owner == "Show Tokyo" })
    }

    func testWorldPlanCancelsEarlierOwnerQuestion() async throws {
        let held = HeldModel()
        let model = WorldPlanModel(firstJob: held)
        let core = try engine(model)
        let question = Task { await core.handle(.ask(question: "Tell a synthetic joke")) }
        await held.waitUntilRunning()
        _ = await core.handle(.worldPlan(question: "Show Tokyo"))
        let response = await question.value
        XCTAssertTrue(held.wasCancelled)
        XCTAssertEqual(response, .refused(code: "cancelled"))
        let memory = await core.memory
        XCTAssertTrue(memory.exchanges.isEmpty)
    }

    private func engine(_ model: any ModelClient) throws -> CoreEngine {
        let instant = now
        return try CoreEngine(
            store: MemoryStore(), collectors: [], model: model,
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: .gmt),
            options: .init(modelName: "synthetic-model"), clock: { instant }
        )
    }
}

private extension CoreEngine {
    func seedWorldTestMemory(_ book: MemoryBook) {
        memory = book
    }
}

actor WorldPlanModel: ModelClient {
    let text: String
    let status: ModelJobResult.Status
    let throwsError: Bool
    let firstJob: HeldModel?
    var jobs: [ModelJob] = []

    init(
        text: String = #"{"actions":[]}"#, status: ModelJobResult.Status = .completed,
        throwsError: Bool = false, firstJob: HeldModel? = nil
    ) {
        self.text = text
        self.status = status
        self.throwsError = throwsError
        self.firstJob = firstJob
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        jobs.append(job)
        if jobs.count == 1, let firstJob {
            return try await firstJob.run(job)
        }
        if throwsError {
            throw StoreUnavailable(code: .unreadable)
        }
        return ModelJobResult(
            jobID: job.id, status: status, text: status == .completed ? text : nil,
            failure: status == .failed ? .internalError : nil
        )
    }

    func cancel(jobID: String) async {
        await firstJob?.cancel(jobID: jobID)
    }
}
