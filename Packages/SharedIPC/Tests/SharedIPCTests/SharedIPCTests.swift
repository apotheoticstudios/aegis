import AegisKit
import Foundation
@testable import SharedIPC
import XCTest

/// The XPC plumbing, end to end over in-process anonymous listeners (no launchd, synthetic data only).
final class SharedIPCTests: XCTestCase {
    func testRequirementPinsAnchorTeamAndIdentifiers() {
        XCTAssertEqual(
            CodeSigning.requirement(identifiers: ["dev.aegis.core", "dev.aegis.app"], team: "ABCDE12345"),
            #"anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" and (identifier "dev.aegis.core" or identifier "dev.aegis.app")"#
        )
        XCTAssertNil(CodeSigning.requirement(identifiers: ["dev.aegis.core"], team: nil))
        XCTAssertNil(CodeSigning.requirement(identifiers: [], team: "ABCDE12345"))
    }

    func testCoreRequestsRoundTripOverXPC() async {
        let host = XPCListenerHost(anonymousFor: CoreXPCProtocol.self, exported: CoreXPCExporter(service: FakeCore()))
        host.resume()
        defer { host.invalidate() }
        let client = CoreXPCClient(target: .endpoint(host.endpoint))
        defer { client.invalidate() }
        let lookup = await client.handle(.publicLookup(question: "astronomy"))
        guard case let .publicLookup(plan) = lookup else { return XCTFail("Round-trips the approved phrase") }
        XCTAssertEqual(plan.query, "astronomy")
        let empty = await client.handle(.answerPublic(planID: plan.id, sources: []))
        XCTAssertEqual(empty, .refused(code: "web_no_results"))
        let status = await client.handle(.status)
        XCTAssertEqual(status, .status(FakeCore.status))
        let refresh = await client.handle(.refreshBrief(reason: .user))
        XCTAssertEqual(refresh, .accepted(jobID: "job-1"))
        let suggestions = await client.handle(.ruleSuggestions)
        XCTAssertEqual(suggestions, .ruleSuggestions([]))
        let dismissed = await client.handle(.dismissSuggestion(personID: "handle:example@example.com", kind: .mute))
        XCTAssertEqual(dismissed, .ruleSuggestions([]))
    }

    func testModelJobsRoundTripAndCancelIsForwarded() async throws {
        let model = FakeModel()
        let idle = IdleExit(seconds: 60) {}
        let host = XPCListenerHost(anonymousFor: ModelXPCProtocol.self, exported: ModelXPCExporter(model: model, activity: idle))
        host.resume()
        defer { host.invalidate() }
        let client = ModelXPCClient(target: .endpoint(host.endpoint))
        defer { client.invalidate() }
        let result = try await client.run(Self.job(id: "job-7"))
        XCTAssertEqual(result, ModelJobResult(jobID: "job-7", status: .completed, text: "{\"items\": []}"))
        await client.cancel(jobID: "job-7")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.cancelled, ["job-7"])
    }

    func testInvalidJobsAreRefusedBeforeTheModelRuns() async throws {
        let model = FakeModel()
        let host = XPCListenerHost(anonymousFor: ModelXPCProtocol.self, exported: ModelXPCExporter(model: model))
        host.resume()
        defer { host.invalidate() }
        let client = ModelXPCClient(target: .endpoint(host.endpoint))
        defer { client.invalidate() }
        var oversized = Self.job(id: "job-8")
        oversized.user = String(repeating: "x", count: ModelJob.maxUserBytes + 1)
        let result = try await client.run(oversized)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.failure, .internalError)
        XCTAssertEqual(model.ran, 0)
    }

    func testIdleExitWaitsForRunningJobs() {
        let fired = expectation(description: "idle exit")
        let exited = LockedFlag()
        let idle = IdleExit(seconds: 0.2) {
            exited.set()
            fired.fulfill()
        }
        idle.begin()
        idle.arm()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(exited.value, "a running job holds the exit back")
        idle.end()
        wait(for: [fired], timeout: 2)
    }

    static func job(id: String) -> ModelJob {
        ModelJob(
            id: id, model: "synthetic", system: "Synthetic system prompt", user: "Synthetic events",
            maxTokens: 100, deadline: Date().addingTimeInterval(30), inputRevision: "synthetic-1"
        )
    }
}

struct FakeCore: CoreService {
    static let status = CoreStatus(sources: [], lastBriefAt: nil, nextBriefAt: nil, generating: true)

    func handle(_ request: CoreRequest) async -> CoreResponse {
        switch request {
        case let .publicLookup(question):
            .publicLookup(PublicLookupPlan(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000037")!,
                query: question,
                expiresAt: Date(timeIntervalSince1970: 100)
            ))
        case .answerPublic: .refused(code: "web_no_results")
        case .latestBrief: .brief(nil)
        case .status, .setBriefTime: .status(Self.status)
        case .refreshBrief: .accepted(jobID: "job-1")
        case .prepareModel: .accepted(jobID: "warm")
        case .sources: .events([])
        case .schedule: .schedule(occurrences: [], reminders: [])
        case .ask: .refused(code: "busy")
        case .prep: .refused(code: "busy")
        case .worldPlan: .worldPlan(actions: [], say: nil)
        case .commandPlan: .commandPlan(nil)
        case .people: .people([])
        case .filtered, .trustSender, .markJunk: .filtered([])
        case .rules, .mute, .unmute, .vip, .unvip, .addKeyword, .removeKeyword: .rules(.empty)
        case .draftReply: .refused(code: "nothing_open")
        case .interpret: .refused(code: "not_a_command")
        case .commitments: .commitments([])
        case .done: .done([])
        case .ruleSuggestions, .dismissSuggestion: .ruleSuggestions([])
        case .morningRoutine, .decideRoutine, .routineDone: .morningRoutine(MorningRoutine(day: Date(timeIntervalSince1970: 0)))
        case .memories, .forgetMemory: .memories([])
        case .personality, .setPersonality: .personality(.standard)
        case .partialReply: .partialReply("")
        case .converse: .refused(code: "busy")
        case .handedOff: .accepted(jobID: "handed-off")
        case .activity: .activity(HourlyActivity(start: Date(timeIntervalSince1970: 0), counts: [:]))
        case .tuneUp: .tuneUp(ModelMetrics())
        }
    }
}

final class FakeModel: ModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledIDs: [String] = []
    private var runs = 0

    var cancelled: [String] {
        lock.withLock { cancelledIDs }
    }

    var ran: Int {
        lock.withLock { runs }
    }

    func run(_ job: ModelJob) async throws -> ModelJobResult {
        lock.withLock { runs += 1 }
        return ModelJobResult(jobID: job.id, status: .completed, text: "{\"items\": []}")
    }

    func cancel(jobID: String) async {
        lock.withLock { cancelledIDs.append(jobID) }
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var value: Bool {
        lock.withLock { raised }
    }

    func set() {
        lock.withLock { raised = true }
    }
}
