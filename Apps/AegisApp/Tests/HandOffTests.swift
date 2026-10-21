@testable import Aegis
import AegisKit
import XCTest

final class HandOffTests: XCTestCase {
    func testLaunchdPollingDistinguishesWaitingRunningAndExitedJobs() {
        XCTAssertEqual(PlanRunner.state(from: #"{ "Label" = "synthetic"; }"#), .pending)
        XCTAssertEqual(PlanRunner.state(from: #"{ "PID" = 123; "LastExitStatus" = 0; }"#), .running)
        XCTAssertEqual(PlanRunner.state(from: #"{ "LastExitStatus" = 0; }"#), .finished(0))
        XCTAssertEqual(PlanRunner.state(from: #"{ "LastExitStatus" = 2; }"#), .finished(2))
        XCTAssertEqual(PlanRunner.state(from: #"{ "LastExitStatus" = -15; }"#), .finished(-15))
    }

    func testArgumentsKeepThePromptLiteralAndDoNotUseTheSharedDaemon() throws {
        let request = CloudHandOff.Request(provider: .chatgpt, question: "--help; $(echo example)", history: [])
        let arguments = PlanRunner.arguments(
            codex: "/synthetic/codex", request: request, folder: URL(fileURLWithPath: "/synthetic/task folder"),
            reply: URL(fileURLWithPath: "/synthetic/reply"), sandbox: "read-only", effort: "low"
        )
        XCTAssertEqual(arguments.suffix(2), ["--", CloudHandOff.planPrompt(request)])
        XCTAssertTrue(arguments.contains("--no-daemon"))
        XCTAssertTrue(arguments.contains("--ignore-user-config"))
        XCTAssertTrue(arguments.contains("--ignore-rules"))
        XCTAssertTrue(arguments.contains("--ephemeral"))
        XCTAssertTrue(arguments.contains("project_doc_max_bytes=0"))
        XCTAssertTrue(arguments.contains("sandbox_workspace_write.exclude_tmpdir_env_var=true"))
        XCTAssertTrue(arguments.contains("sandbox_workspace_write.exclude_slash_tmp=true"))
        XCTAssertEqual(try arguments[XCTUnwrap(arguments.firstIndex(of: "-C")) + 1], "/synthetic/task folder")
        XCTAssertEqual(try arguments[XCTUnwrap(arguments.firstIndex(of: "-a")) + 1], "never")
    }

    func testTaskFoldersRejectSymlinksAndSiblingPrefixes() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)").resolvingSymlinksInPath()
        let base = root.appendingPathComponent("tasks")
        let folder = base.appendingPathComponent("new task")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        XCTAssertTrue(PlanRunner.validFolder(folder, base: base))
        XCTAssertFalse(PlanRunner.validFolder(base, base: base))
        let sibling = root.appendingPathComponent("tasks-other")
        try files.createDirectory(at: sibling, withIntermediateDirectories: true)
        XCTAssertFalse(PlanRunner.validFolder(sibling, base: base))
        let link = base.appendingPathComponent("link")
        try files.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertFalse(PlanRunner.validFolder(link, base: base))
        let baseLink = root.appendingPathComponent("linked tasks")
        try files.createSymbolicLink(at: baseLink, withDestinationURL: base)
        XCTAssertFalse(PlanRunner.validFolder(folder, base: baseLink))
        XCTAssertFalse(PlanRunner.validFolder(baseLink.appendingPathComponent("new task"), base: baseLink))
    }

    @MainActor
    func testCreatingATaskNeverReusesAnExistingFolder() throws {
        let files = FileManager.default
        let base = files.temporaryDirectory.appendingPathComponent("task-create-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? files.removeItem(at: base) }
        let folder = base.appendingPathComponent("example")
        try PlanRunner.createTaskFolder(folder, base: base)
        XCTAssertThrowsError(try PlanRunner.createTaskFolder(folder, base: base))
        let link = base.appendingPathComponent("linked")
        try files.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertThrowsError(try PlanRunner.createTaskFolder(link, base: base))
        XCTAssertThrowsError(try PlanRunner.createTaskFolder(base.deletingLastPathComponent(), base: base))
    }

    func testGPTVersionsCompareNumericallyAndExcludeSpecialisedModels() {
        XCTAssertEqual(CloudClient.newest(["gpt-5.9", "gpt-5.10", "gpt-5.11-mini", "gpt-4o"]), "gpt-5.10")
        XCTAssertNil(CloudClient.newest(["gpt-5-mini", "gpt-4o"]))
    }

    func testAPITasksRejectAnInvalidFolderBeforeReadingKeysOrSending() async {
        let result = await CloudClient().task(
            .init(provider: .chatgpt, question: "make a synthetic table", history: [], work: .task),
            in: URL(fileURLWithPath: "/synthetic/outside"), base: URL(fileURLWithPath: "/synthetic/tasks")
        )
        guard case .failure(.unwritable) = result else { return XCTFail("expected a folder refusal") }
    }

    @MainActor
    func testClearingThePanelProtectsTheNewerQuestionFromALateReply() async {
        let core = SuspendedHandOffCore()
        let model = PanelModel(service: core, actions: nil)
        let first = Task { await model.ask("first example question") }
        await core.waitUntilAsked()
        model.clearAnswer()
        await model.ask("second example question")
        let count = await core.questionCount
        XCTAssertEqual(count, 2)
        await core.finish()
        await first.value
        guard case let .failed(question, _) = model.askState else { return XCTFail("Keeps the second request's failure.") }
        XCTAssertEqual(question, "second example question")
        XCTAssertEqual(model.thread.map(\.question), ["second example question"])
    }

    @MainActor
    func testTasksRequireAWritableActionLogBeforeStartIsOffered() async {
        for actions in [nil, ActionLog(persistence: UnwritableHandOffLog())] {
            let model = PanelModel(service: TaskHandOffCore(), actions: actions)
            await model.ask("ask ChatGPT make a synthetic table")
            XCTAssertNil(model.pendingTask)
            guard case .failed = model.askState else { return XCTFail("expected an audit refusal") }
        }
    }

    @MainActor
    func testTaskProposalsAreLoggedWithoutTheirText() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("task-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try ActionLogFile(url: folder.appendingPathComponent("audit.json"))
        let model = PanelModel(service: TaskHandOffCore(), actions: ActionLog(persistence: file))
        await model.ask("ask ChatGPT make a synthetic table")
        XCTAssertNotNil(model.pendingTask)
        XCTAssertEqual(try file.load().map(\.outcomeCode), [.proposed, .awaitingConfirmation])
        let text = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertFalse(text.contains("synthetic table"))
        await model.cancelTask()
        XCTAssertEqual(try file.load().last?.outcomeCode, .cancelled)
    }
}

private struct TaskHandOffCore: CoreService {
    func handle(_: CoreRequest) async -> CoreResponse {
        .handOff(.init(provider: .chatgpt, question: "make a synthetic table", history: [], work: .task))
    }
}

private struct UnwritableHandOffLog: ActionLogPersistence {
    let maxEntries = 10
    func load() throws -> [ActionLogEntry] {
        []
    }

    func append(_: ActionLogEntry) throws {
        throw ActionLogError.persistenceFailure
    }
}

private actor SuspendedHandOffCore: CoreService {
    private(set) var questionCount = 0
    private var answer: CheckedContinuation<CoreResponse, Never>?
    private var entered: CheckedContinuation<Void, Never>?

    func handle(_ request: CoreRequest) async -> CoreResponse {
        switch request {
        case .ask, .converse:
            questionCount += 1
            guard questionCount == 1 else { return .refused(code: "busy") }
            return await withCheckedContinuation {
                answer = $0
                entered?.resume()
                entered = nil
            }
        default:
            return .refused(code: "unavailable")
        }
    }

    func waitUntilAsked() async {
        if answer != nil {
            return
        }
        await withCheckedContinuation { entered = $0 }
    }

    func finish() {
        answer?.resume(returning: .answer(Answer(
            text: "Example answer.", eventIDs: [], scheduleIDs: [], model: "aegis", generatedAt: Date()
        )))
        answer = nil
    }
}
