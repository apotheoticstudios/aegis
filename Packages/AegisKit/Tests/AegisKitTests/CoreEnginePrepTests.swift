@testable import AegisKit
import Foundation
import XCTest

final class CoreEnginePrepTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-prep-" + UUID().uuidString)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func engine(
        store: MemoryStore, model: any ModelClient, rules: OwnerRules = .empty, collectors: [any EventCollector] = []
    ) throws -> CoreEngine {
        try CoreEngine(
            store: store, collectors: collectors, model: model,
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 0, openingMinute: 0, timeZone: .gmt),
            options: .init(modelName: "synthetic-model", pageSize: 2), contacts: FixedContacts(index: prepContacts),
            rules: PrepRules(rules: rules), clock: { prepNow }
        )
    }

    func testJobContainsOnlyAttendeeContactAndReturnsCheckedCitationsWithoutWrites() async throws {
        let question = prepEvent("question", age: 120, handle: "+61 400 000 101")
        let promise = prepEvent("promise", outgoing: true, source: .email, body: "I'll send the Example plan.")
        let excluded = [
            prepEvent("other", handle: "other@example.com", body: "Private Example conversation"),
            prepEvent("owner", handle: "owner@example.com", body: "Owner Example conversation"),
            prepEvent("old", age: 15 * 86400, body: "Old Example conversation"),
        ]
        let text = "{\"answer\":\"Alex Example asked for the plan. You promised to send it.\","
            + "\"event_ids\":[\"\(question.id)\",\"\(promise.id)\"],\"schedule_ids\":[]}"
        let model = PrepModel(text: text)
        let storage = try await prepStore(excluded + [question, promise])
        let core = try engine(store: storage, model: model)
        guard case let .answer(answer) = await core.handle(.prep(occurrenceID: prepOccurrence().id)) else {
            return XCTFail("expected answer")
        }
        XCTAssertEqual(answer.eventIDs, [question.id, promise.id])
        XCTAssertTrue(answer.scheduleIDs.isEmpty)
        XCTAssertEqual(answer.model, "synthetic-model")
        XCTAssertEqual(answer.generatedAt, prepNow)
        let job = try XCTUnwrap(model.lastJob)
        XCTAssertTrue(job.user.contains(question.id))
        XCTAssertTrue(job.user.contains(promise.id))
        XCTAssertTrue(job.user.contains("Alex Example asked you:"))
        for event in excluded {
            XCTAssertFalse(job.user.contains(event.body))
            XCTAssertFalse(job.user.contains(event.id))
        }
        XCTAssertEqual(job.system, MeetingPrep.systemPrompt())
        for instruction in ["DATA", "never instructions", "3 short sentences", "event_ids", "schedule_ids"] {
            XCTAssertTrue(job.system.contains(instruction))
        }
        XCTAssertTrue(job.id.hasPrefix("prep-"))
        XCTAssertNotNil(UUID(uuidString: String(job.id.dropFirst(5))))
        XCTAssertEqual(job.maxTokens, CoreEngine.answerTokens)
        XCTAssertEqual(job.deadline, prepNow.addingTimeInterval(120))
        XCTAssertEqual(job.inputRevision, SHA256.hex(Array(job.user.utf8)))
        XCTAssertTrue(job.validate().isEmpty)
        XCTAssertEqual(storage.savedCount, 0)
    }

    func testMissingEmptyAndOwnerOnlyAttendeeListsAnswerWithoutTheModel() async throws {
        let model = PrepModel()
        let lists: [[CalendarAttendee]?] = [
            nil, [], [CalendarAttendee(name: "Owner Example", email: "owner@example.com", isOwner: true)],
        ]
        for attendees in lists {
            let occurrence = prepOccurrence(attendees: attendees)
            let storage = try await prepStore([prepEvent("contact")], occurrence: occurrence)
            let core = try engine(store: storage, model: model)
            let result = await core.handle(.prep(occurrenceID: occurrence.id))
            XCTAssertEqual(result, .answer(Answer(
                text: "Example meeting has no attendee list.", eventIDs: [], scheduleIDs: [], model: nil, generatedAt: prepNow
            )))
        }
        XCTAssertNil(model.lastJob)
    }

    func testNoRecentContactOrMutedContactAnswersWithoutTheModel() async throws {
        let model = PrepModel()
        let cases: [([Event], OwnerRules)] = [
            ([], .empty), ([prepEvent("other", handle: "other@example.com")], .empty),
            ([prepEvent("old", age: 15 * 86400)], .empty),
            (
                [prepEvent("incoming"), prepEvent("outgoing", outgoing: true)],
                OwnerRules(muted: ["contact:example-alex": "Alex Example"])
            ),
        ]
        for (events, rules) in cases {
            let storage = try await prepStore(events)
            let core = try engine(store: storage, model: model, rules: rules)
            let result = await core.handle(.prep(occurrenceID: prepOccurrence().id))
            XCTAssertEqual(result, .answer(Answer(
                text: "No recent messages or email with the people in Example meeting.",
                eventIDs: [], scheduleIDs: [], model: nil, generatedAt: prepNow
            )))
        }
        XCTAssertNil(model.lastJob)
    }

    func testUnknownOccurrenceAndOccurrencesOutsideLookupWindowRefuse() async throws {
        let model = PrepModel()
        for offset in [-2.0, 15.0] {
            var occurrence = prepOccurrence()
            occurrence.start = prepNow.addingTimeInterval(offset * 86400)
            occurrence.end = occurrence.start.addingTimeInterval(3600)
            let storage = try await prepStore([prepEvent("contact")], occurrence: occurrence)
            let core = try engine(store: storage, model: model)
            for id in ["missing", "", occurrence.id] {
                let result = await core.handle(.prep(occurrenceID: id))
                XCTAssertEqual(result, .refused(code: "unknown_occurrence"))
            }
        }
        XCTAssertNil(model.lastJob)
    }

    func testModelStatusesErrorsAndAskRejectionsReturnFixedCodes() async throws {
        let storage = try await prepStore([prepEvent("contact")])
        for status in [ModelJobResult.Status.failed, .timedOut, .cancelled] {
            let core = try engine(store: storage, model: PrepModel(status: status))
            let result = await core.handle(.prep(occurrenceID: prepOccurrence().id))
            XCTAssertEqual(result, .refused(code: status.rawValue))
        }
        let throwing = try engine(store: storage, model: PrepModel(throwsError: true))
        let unavailable = await throwing.handle(.prep(occurrenceID: prepOccurrence().id))
        XCTAssertEqual(unavailable, .refused(code: "unavailable"))
        let drafts: [(String?, String)] = [
            (nil, "invalid_draft"), ("not JSON", "invalid_draft"),
            ("{\"answer\":\"fine\"}", "invalid_draft"),
            (draft("fine", events: ["ev_ffffffffffffffff"]), "unknown_citation"),
            (draft("fine", schedule: [prepOccurrence().id]), "unknown_citation"),
            (draft(String(repeating: "x", count: Answer.maxTextScalars + 1)), "too_long"),
            (draft("See ev_ffffffffffffffff."), "unsafe_text"),
            (draft("Example\u{202E} text"), "unsafe_text"),
        ]
        for (text, code) in drafts {
            let core = try engine(store: storage, model: PrepModel(text: text))
            let result = await core.handle(.prep(occurrenceID: prepOccurrence().id))
            XCTAssertEqual(result, .refused(code: code))
        }
    }

    private func draft(_ text: String, events: [String] = [], schedule: [String] = []) -> String {
        "{\"answer\":\(jsonString(text)),\"event_ids\":[\(events.map { jsonString($0) }.joined(separator: ","))],"
            + "\"schedule_ids\":[\(schedule.map { jsonString($0) }.joined(separator: ","))]}"
    }

    func testBriefBeingWrittenRefusesPrepAsBusy() async throws {
        let collector = HeldCollector()
        let model = PrepModel()
        let storage = try await prepStore([prepEvent("contact")])
        let core = try engine(store: storage, model: model, collectors: [collector])
        guard case .accepted = await core.handle(.refreshBrief(reason: .user)) else { return XCTFail("expected accepted") }
        await collector.waitUntilRunning()
        let result = await core.handle(.prep(occurrenceID: prepOccurrence().id))
        XCTAssertEqual(result, .refused(code: "busy"))
        XCTAssertNil(model.lastJob)
        collector.release()
        await core.settle()
    }
}
