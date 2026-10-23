@testable import Aegis
import AegisKit
import XCTest

final class QuestionPrivacyTests: XCTestCase {
    @MainActor func testQuestionPathRejectsCloudTasksWithoutPostingOrCreatingAProposal() async {
        let service = UnexpectedHandOff()
        let model = PanelModel(service: service, actions: nil)
        await model.submit("Explain gravity")
        guard case let .failed(_, message) = model.askState else { return XCTFail("Must refuse the cloud handoff") }
        XCTAssertTrue(message.contains("read-only"))
        XCTAssertNil(model.pendingTask)
        let requests = await service.requests
        XCTAssertTrue(requests.contains(.ask(question: "Explain gravity")))
        XCTAssertFalse(requests.contains {
            if case .converse = $0 {
                true
            } else {
                false
            }
        })
    }

    func testCitationFailuresAndModelFailuresExplainTheActualProblem() {
        XCTAssertTrue(BriefPresentation.askMessage("unknown_citation").contains("verify"))
        XCTAssertTrue(BriefPresentation.askMessage("model_missing").contains("isn't installed"))
        XCTAssertFalse(BriefPresentation.askMessage("internal_error").contains("another way"))
    }
}

private actor UnexpectedHandOff: CoreService {
    var requests: [CoreRequest] = []
    func handle(_ request: CoreRequest) async -> CoreResponse {
        requests.append(request)
        if case .ask = request {
            return .handOff(.init(provider: .claude, question: "Make an Example report", history: [], work: .task))
        }
        return .refused(code: "not_a_command")
    }
}
