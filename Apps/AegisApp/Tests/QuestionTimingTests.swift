@testable import Aegis
import AegisKit
import XCTest

@MainActor
final class QuestionTimingTests: XCTestCase {
    func testLateSpokenReplyCannotOverwriteOrReadTheNextTypedAnswer() async {
        let core = DelayedQuestionCore()
        let model = PanelModel(service: core, actions: nil)
        var finished = 0
        model.questionFinished = { finished += 1 }
        let first = Task { await model.askAloud("First synthetic question") }
        await core.waitForRequests(1)
        let second = Task { await model.ask("Second synthetic question") }
        await core.waitForRequests(2)
        XCTAssertEqual(model.askState, .asking("Second synthetic question"))
        await core.reply(1, with: .answer(Self.answer("Second answer.")))
        await second.value
        await core.reply(0, with: .answer(Self.answer("Obsolete first answer.")))
        await first.value
        XCTAssertEqual(model.askState, .answered(question: "Second synthetic question", answer: Self.answer("Second answer.")))
        XCTAssertEqual(model.thread.map(\.question), ["Second synthetic question"])
        XCTAssertFalse(model.voice.speaking, "A stale askAloud must not read the newer typed reply either.")
        XCTAssertEqual(finished, 1)
    }

    func testEndingAnUnfinishedConversationRejectsItsLateReplyAndAllowsANewQuestion() async {
        let core = DelayedQuestionCore()
        let model = PanelModel(service: core, actions: nil)
        let first = Task { await model.askAloud("First synthetic question") }
        await core.waitForRequests(1)
        model.endVoiceConversation()
        XCTAssertEqual(model.askState, .idle)
        let second = Task { await model.ask("New conversation") }
        await core.waitForRequests(2)
        await core.reply(0, with: .refused(code: "unavailable"))
        await first.value
        XCTAssertEqual(model.askState, .asking("New conversation"))
        XCTAssertFalse(model.voice.speaking)
        await core.reply(1, with: .answer(Self.answer("New answer.")))
        await second.value
        XCTAssertEqual(model.thread.map(\.question), ["New conversation"])
    }

    func testClosingThePanelPreventsLateSpeechAndReplyResurrection() async {
        let core = DelayedQuestionCore()
        let model = PanelModel(service: core, actions: nil)
        let question = Task { await model.askAloud("A synthetic question") }
        await core.waitForRequests(1)
        model.panelClosed()
        await core.reply(0, with: .answer(Self.answer("Late answer.")))
        await question.value
        XCTAssertEqual(model.askState, .idle)
        XCTAssertTrue(model.thread.isEmpty)
        XCTAssertFalse(model.voice.speaking)
    }

    func testDelayedInterpretationCannotResubmitAnObsoleteQuestion() async {
        let core = DelayedQuestionCore()
        let model = PanelModel(service: core, actions: nil)
        let first = Task { await model.submit("First synthetic question") }
        await core.waitForRequests(1)
        let second = Task { await model.submit("Second synthetic question") }
        await core.waitForRequests(2)
        await core.reply(1, with: .refused(code: "not_a_command"))
        await core.waitForRequests(3)
        await core.reply(2, with: .answer(Self.answer("Second answer.")))
        await second.value
        await core.reply(0, with: .refused(code: "not_a_command"))
        await first.value
        let count = await core.requestCount
        XCTAssertEqual(count, 3, "Only the current interpretation should proceed to an answer request.")
        XCTAssertEqual(model.thread.map(\.question), ["Second synthetic question"])
    }

    func testFailureReleasesVoiceCaptureImmediatelyWithoutPlayback() async {
        let core = DelayedQuestionCore()
        let model = PanelModel(service: core, actions: nil)
        let wake = WakeListener()
        model.questionFinished = { wake.answerFinished() }
        wake.wakeDetected()
        wake.segment("A synthetic question")
        XCTAssertEqual(wake.inputMode, .paused)
        let question = Task { await model.ask("A synthetic question") }
        await core.waitForRequests(1)
        await core.reply(0, with: .refused(code: "unavailable"))
        await question.value
        XCTAssertEqual(wake.inputMode, .question, "Resume now, without the old ninety-second stall.")
        var asked: [String] = []
        wake.ask = { asked.append($0) }
        wake.segment("An unrelated question")
        XCTAssertEqual(asked, ["An unrelated question"])
    }

    func testReadyAnswerReleasesCaptureBeforeCitationLookupCompletes() async {
        let core = DelayedQuestionCore(holdSources: true)
        let model = PanelModel(service: core, actions: nil)
        var finished = 0
        model.questionFinished = { finished += 1 }
        let question = Task { await model.ask("A synthetic question") }
        await core.waitForRequests(1)
        var answer = Self.answer("The current answer.")
        answer.eventIDs = ["ev_0123456789abcdef"]
        await core.reply(0, with: .answer(answer))
        await core.waitForRequests(2)
        XCTAssertEqual(finished, 1, "Fetching citation details must not delay completing the answer.")
        XCTAssertEqual(model.askState, .answered(question: "A synthetic question", answer: answer))
        await core.reply(1, with: .events([]))
        await question.value
    }

    private static func answer(_ text: String) -> Answer {
        Answer(text: text, eventIDs: [], scheduleIDs: [], model: "synthetic", generatedAt: Date(timeIntervalSince1970: 1))
    }
}

/// No real store, microphone, model or cloud request. Replies can be released in any order.
private actor DelayedQuestionCore: CoreService {
    private var replies: [Int: CheckedContinuation<CoreResponse, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var requestCount = 0
    private let holdSources: Bool

    init(holdSources: Bool = false) {
        self.holdSources = holdSources
    }

    func handle(_ request: CoreRequest) async -> CoreResponse {
        if case .sources = request, !holdSources {
            return .events([])
        }
        let index = requestCount
        requestCount += 1
        return await withCheckedContinuation { continuation in
            replies[index] = continuation
            let ready = waiters.filter { requestCount >= $0.0 }
            waiters.removeAll { requestCount >= $0.0 }
            for (_, waiter) in ready {
                waiter.resume()
            }
        }
    }

    func waitForRequests(_ count: Int) async {
        guard requestCount < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func reply(_ index: Int, with response: CoreResponse) {
        replies.removeValue(forKey: index)?.resume(returning: response)
    }
}
