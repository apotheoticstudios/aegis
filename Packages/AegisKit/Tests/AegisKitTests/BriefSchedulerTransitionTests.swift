import AegisKit
import Foundation
import XCTest

final class BriefSchedulerTransitionTests: XCTestCase {
    private func calendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))
        return calendar
    }

    private func now() throws -> Date {
        try XCTUnwrap(ContractTime.parse("2026-10-07T20:58:00Z"))
    }

    func testPowerConditionsChangingDuringRefreshPreventGeneration() throws {
        let calendar = try calendar()
        let now = try now()
        for (thermal, power, reason) in [(true, false, "thermal_serious"), (false, true, "low_power")] {
            var schedule = BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: calendar.timeZone)
            XCTAssertEqual(step(&schedule, .tick(now), calendar: calendar), [.refreshSources])
            let id = try XCTUnwrap(schedule.job?.id)
            XCTAssertEqual(step(&schedule, .conditions(thermalSerious: thermal, lowPower: power, at: now), calendar: calendar), [])
            XCTAssertEqual(
                step(&schedule, .sourcesRefreshed(jobID: id, inputTime: now, at: now), calendar: calendar),
                [.keepPreviousBrief, .publishDeferred(reason: reason)]
            )
            XCTAssertNil(schedule.job)
            XCTAssertEqual(
                step(&schedule, .conditions(thermalSerious: false, lowPower: false, at: now), calendar: calendar), [.refreshSources]
            )
            XCTAssertNotEqual(schedule.job?.id, id)
        }
    }

    func testDeferredAcrossMidnightCoalescesToCurrentWindow() throws {
        let calendar = try calendar()
        let now = try now()
        var schedule = BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: calendar.timeZone)
        _ = step(&schedule, .conditions(thermalSerious: true, lowPower: false, at: now), calendar: calendar)
        // Clear heat just after midnight, before the next morning is due.
        let midnight = try XCTUnwrap(ContractTime.parse("2026-10-08T14:00:00Z"))
        XCTAssertEqual(
            step(&schedule, .conditions(thermalSerious: false, lowPower: false, at: midnight), calendar: calendar), [.refreshSources]
        )
        XCTAssertEqual(schedule.job?.opening, schedule.opening(on: midnight, calendar: calendar))
    }

    func testSleepingStateRoundTripsAndWaitsForWake() throws {
        let calendar = try calendar()
        let now = try now()
        var schedule = BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: calendar.timeZone)
        _ = step(&schedule, .sleep(now.addingTimeInterval(-1)), calendar: calendar)
        let data = try IPCCoding.encode(schedule)
        schedule = try IPCCoding.decode(BriefSchedule.self, from: data)
        XCTAssertEqual(step(&schedule, .tick(now), calendar: calendar), [])
        XCTAssertEqual(step(&schedule, .wake(now), calendar: calendar), [.refreshSources])
    }

    func testMeasuredLeadMovesRefreshThreshold() throws {
        let calendar = try calendar()
        let opening = try now().addingTimeInterval(120)
        var schedule = BriefSchedule(
            openingHour: 7, openingMinute: 0, timeZone: calendar.timeZone, durations: [TimeInterval](repeating: 240, count: 20)
        )
        XCTAssertEqual(schedule.lead, 300)
        XCTAssertEqual(step(&schedule, .tick(opening.addingTimeInterval(-301)), calendar: calendar), [])
        XCTAssertEqual(step(&schedule, .tick(opening.addingTimeInterval(-300)), calendar: calendar), [.refreshSources])
    }

    func testManualBypassesBackoffAndSuccessfulPublicationResetsIt() throws {
        let calendar = try calendar()
        let now = try now()
        var schedule = BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: calendar.timeZone)
        _ = step(&schedule, .tick(now), calendar: calendar)
        let first = try XCTUnwrap(schedule.job?.id)
        _ = step(&schedule, .jobFinished(jobID: first, outcome: .failed, duration: 0, at: now), calendar: calendar)
        XCTAssertEqual(step(&schedule, .userRefresh(now), calendar: calendar), [.refreshSources])
        let second = try XCTUnwrap(schedule.job?.id)
        _ = step(&schedule, .sourcesRefreshed(jobID: second, inputTime: now, at: now), calendar: calendar)
        XCTAssertEqual(
            step(&schedule, .jobFinished(jobID: second, outcome: .completed, duration: 30, at: now), calendar: calendar),
            [.publishBrief(jobID: second)]
        )
        _ = step(&schedule, .userRefresh(now), calendar: calendar)
        let third = try XCTUnwrap(schedule.job?.id)
        _ = step(&schedule, .jobFinished(jobID: third, outcome: .failed, duration: 0, at: now), calendar: calendar)
        XCTAssertEqual(schedule.state, .backoff(until: now.addingTimeInterval(60)))
        XCTAssertEqual(schedule.lastBriefAt, now)
    }

    func testExpiredCompletionCannotPublishBeforeWatchdogTick() throws {
        let calendar = try calendar()
        let now = try now()
        for refreshing in [true, false] {
            var schedule = BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: calendar.timeZone)
            _ = step(&schedule, .tick(now), calendar: calendar)
            let id = try XCTUnwrap(schedule.job?.id)
            if !refreshing {
                _ = step(&schedule, .sourcesRefreshed(jobID: id, inputTime: now, at: now), calendar: calendar)
            }
            let deadline = try XCTUnwrap(schedule.job?.deadline)
            let event: ScheduleEvent = refreshing
                ? .sourcesRefreshed(jobID: id, inputTime: deadline, at: deadline)
                : .jobFinished(jobID: id, outcome: .completed, duration: 600, at: deadline)
            XCTAssertEqual(step(&schedule, event, calendar: calendar), [.keepPreviousBrief])
            XCTAssertNil(schedule.lastBriefAt)
            XCTAssertNil(schedule.job)
        }
    }
}
