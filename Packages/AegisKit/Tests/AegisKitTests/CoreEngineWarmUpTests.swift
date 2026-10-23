@testable import AegisKit
import XCTest

final class CoreEngineWarmUpTests: XCTestCase {
    func testPrepareModelAnswersAtOnceAndLoadsTheModelWithAOneTokenJob() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("warm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = RecordingModel()
        let core = try CoreEngine(
            store: MemoryStore(), collectors: [], model: model,
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))),
            options: .init(modelName: "synthetic-model")
        )
        guard case let .accepted(jobID) = await core.handle(.prepareModel) else {
            return XCTFail("expected accepted")
        }
        XCTAssertTrue(jobID.hasPrefix("warm-"))
        for _ in 0 ..< 100 where model.lastInput == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.lastInput, "OK", "a tiny job loads the model; nothing from the owner's data")
        XCTAssertEqual(model.lastSystem, Chat.systemPrompt(), "the chat instructions are read before the first question (#52)")
    }
}
