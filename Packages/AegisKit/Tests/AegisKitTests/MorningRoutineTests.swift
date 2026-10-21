@testable import AegisKit
import XCTest

/// The morning routine (#286): ported approvals, the owner's spoken answers and the engine's decisions.
final class ApprovalReplyTests: XCTestCase {
    private typealias Decision = ApprovalReply.Decision

    func testOpenJarvisForms() {
        XCTAssertEqual(ApprovalReply.parse("abc123def456 yes"), [Decision(target: .id("abc123def456"), approved: true, always: false)])
        XCTAssertEqual(
            ApprovalReply.parse("always no [abc123def456]"),
            [Decision(target: .id("abc123def456"), approved: false, always: true)]
        )
        XCTAssertEqual(ApprovalReply.parse("yes all"), [Decision(target: .all, approved: true, always: false)])
        XCTAssertEqual(ApprovalReply.parse("all always deny"), [Decision(target: .all, approved: false, always: true)])
    }

    func testSpokenAnswers() {
        XCTAssertEqual(ApprovalReply.parse("Yes to 1 and 3"), [
            Decision(target: .number(1), approved: true, always: false), Decision(target: .number(3), approved: true, always: false),
        ])
        XCTAssertEqual(
            ApprovalReply.parse("Aegis, always no to the second one."),
            [Decision(target: .number(2), approved: false, always: true)]
        )
        XCTAssertEqual(ApprovalReply.parse("do all of them"), [Decision(target: .all, approved: true, always: false)])
        XCTAssertEqual(ApprovalReply.parse("no to both"), [Decision(target: .all, approved: false, always: false)])
        XCTAssertEqual(ApprovalReply.parse("always yes", single: true), [Decision(target: .all, approved: true, always: true)])
    }

    func testOtherLinesAreNotAnswers() {
        for line in ["yes", "no", "Yes, what's the weather?", "do my homework", "no idea what you mean", "yes to the moon"] {
            XCTAssertEqual(ApprovalReply.parse(line), [], line)
        }
        XCTAssertEqual(ApprovalReply.parse("do", single: true), [])
    }
}

final class MorningRoutineTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current
        return calendar
    }()

    private var now: Date {
        calendar.date(from: DateComponents(year: 2027, month: 3, day: 1, hour: 7, minute: 30)) ?? Date()
    }

    private func inputs() -> RoutineInputs {
        var memory = MemoryBook.empty
        _ = memory.remember("Mum's birthday is 3 March", now: now)
        let promise = Commitment(
            personID: "contact:example-sam", person: "Example Sam", text: "I'll send the slides tomorrow",
            due: now.addingTimeInterval(86400), madeAt: now.addingTimeInterval(-3600), eventID: "evt-1"
        )
        let suggestion = RuleSuggestion(
            kind: .mute, personID: "handle:news@example.com", name: "Example News",
            reason: "You haven’t replied to Example News’s 9 messages this fortnight",
            evidenceCount: 9
        )
        return RoutineInputs(memory: memory, commitments: [promise], suggestions: [suggestion], skills: ["morning-routine"])
    }

    func testCandidatesComeFromTheOwnersOwnData() {
        let found = MorningRoutine.candidates(inputs(), now: now, calendar: calendar)
        XCTAssertEqual(found.map(\.permissionKey), [
            "skill:morning-routine", "reminder:remembered-date", "reminder:my-promise", "rule:mute:handle:news@example.com",
        ])
        XCTAssertEqual(found.map(\.tier), [.low, .low, .low, .medium])
        XCTAssertEqual(found[1].text, "Add a reminder: Mum's birthday is 3 March (in 2 days)")
        guard case let .reminder(title, due) = found[2].action else { return XCTFail("expected a reminder") }
        XCTAssertEqual(title, "Example Sam: I'll send the slides tomorrow")
        XCTAssertNotNil(due)
        XCTAssertEqual(found[0].id.count, 12)
    }

    func testRememberedDecisionsAndStableNumbers() {
        var approvals = Approvals.empty
        approvals.set("reminder:remembered-date", decision: .alwaysApprove, approved: true, now: now)
        approvals.set("rule:mute:handle:news@example.com", decision: .alwaysDeny, approved: false, now: now)
        var routine = MorningRoutine(day: .distantPast)
        let found = MorningRoutine.candidates(inputs(), now: now, calendar: calendar)
        routine.merge(found, approvals: approvals, now: now, calendar: calendar)
        XCTAssertEqual(routine.proposals.map(\.number), [1, 2, 3])
        XCTAssertEqual(routine.pending.map(\.permissionKey), ["skill:morning-routine", "reminder:my-promise"])
        XCTAssertEqual(routine.toRun.first?.remembered, true)
        // Merging again later the same day keeps numbers and adds nothing twice.
        routine.merge(found, approvals: approvals, now: now.addingTimeInterval(600), calendar: calendar)
        XCTAssertEqual(routine.proposals.count, 3)
        XCTAssertTrue(ApprovalTier.high > .medium)
        XCTAssertFalse(ApprovalTier.high.canRemember)
    }

    func testTheLearningLoopOnlyStopsAsking() {
        var approvals = Approvals.empty
        for _ in 1 ... 3 {
            approvals.record("reminder:my-promise", approved: false, now: now)
        }
        approvals.record("skill:morning-routine", approved: true, now: now)
        XCTAssertTrue(approvals.learnedOff("reminder:my-promise", now: now))
        XCTAssertFalse(approvals.learnedOff("reminder:my-promise", now: now.addingTimeInterval(31 * 86400)), "it asks again after 30 days")
        XCTAssertEqual(approvals.decision(for: "reminder:my-promise"), .ask, "never turned into a remembered decision")
        XCTAssertGreaterThan(approvals.acceptance("skill:morning-routine"), approvals.acceptance("reminder:remembered-date"))
        approvals.record("reminder:my-promise", approved: true, now: now)
        XCTAssertFalse(approvals.learnedOff("reminder:my-promise", now: now), "one yes is enough to keep asking")
    }

    func testApprovalsCountDecisions() {
        var approvals = Approvals.empty
        approvals.set("skill:x", decision: .alwaysApprove, approved: true, now: now)
        approvals.set("skill:x", decision: .alwaysDeny, approved: false, now: now)
        XCTAssertEqual(approvals.rules["skill:x"]?.timesApproved, 1)
        XCTAssertEqual(approvals.rules["skill:x"]?.timesDenied, 1)
        XCTAssertEqual(approvals.decision(for: "skill:x"), .alwaysDeny)
        approvals.clear("skill:x")
        XCTAssertEqual(approvals.decision(for: "skill:x"), .ask)
    }
}

final class CoreEngineRoutineTests: XCTestCase {
    func testDecisionsAreRememberedAndAnsweredJobsStayAnswered() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("routine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let make = {
            try CoreEngine(
                store: MemoryStore(), collectors: [], model: RecordingModel(),
                persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
                initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))),
                options: .init(modelName: "synthetic-model"), routine: RoutineFile(url: folder.appendingPathComponent("routine.json"))
            )
        }
        let core = try make()
        guard case let .morningRoutine(first) = await core.handle(.morningRoutine(skills: ["morning-routine"])) else {
            return XCTFail("expected a routine")
        }
        let skill = try XCTUnwrap(first.pending.first)
        XCTAssertEqual(skill.text, "Run your “morning-routine” skill")
        guard case let .morningRoutine(decided) = await core.handle(.decideRoutine(ids: [skill.id], approved: true, always: true)) else {
            return XCTFail("expected a routine")
        }
        XCTAssertEqual(decided.toRun.map(\.id), [skill.id])
        guard case let .morningRoutine(done) = await core.handle(.routineDone(id: skill.id, succeeded: true)) else {
            return XCTFail("expected a routine")
        }
        XCTAssertEqual(done.proposals.first?.status, .executed)
        guard case .refused(code: "bad_routine") = await core.handle(.decideRoutine(ids: [skill.id], approved: false, always: false)) else {
            return XCTFail("an answered job can't be answered again")
        }
        // Kept across restarts: tomorrow the skill is approved without asking.
        let again = try make()
        let routineState = await again.routine
        XCTAssertEqual(routineState.approvals.decision(for: "skill:morning-routine"), .alwaysApprove)
        guard case .refused(code: "bad_skill") = await again.handle(.morningRoutine(skills: [String(repeating: "x", count: 65)])) else {
            return XCTFail("expected bad_skill")
        }
    }
}
