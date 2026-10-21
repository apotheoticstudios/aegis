@testable import AegisKit
import Foundation
import XCTest

final class BriefSchedulerTests: XCTestCase {
    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(ContractTime.parse(text))
    }

    private func calendar(_ zone: String = "Australia/Brisbane") throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return calendar
    }

    private func schedule(_ calendar: Calendar, hour: Int = 7, minute: Int = 0) -> BriefSchedule {
        BriefSchedule(openingHour: hour, openingMinute: minute, timeZone: calendar.timeZone)
    }

    private func start(_ schedule: inout BriefSchedule, at time: Date, calendar: Calendar) throws -> String {
        XCTAssertEqual(step(&schedule, .tick(time), calendar: calendar), [.refreshSources])
        let id = try XCTUnwrap(schedule.job?.id)
        XCTAssertEqual(
            step(&schedule, .sourcesRefreshed(jobID: id, inputTime: time, at: time), calendar: calendar),
            [.startGeneration(jobID: id)]
        )
        return id
    }

    private func finish(_ schedule: inout BriefSchedule, id: String, at time: Date, calendar: Calendar) -> [ScheduleAction] {
        step(&schedule, .jobFinished(jobID: id, outcome: .completed, duration: 30, at: time), calendar: calendar)
    }

    private func restored(_ schedule: BriefSchedule) throws -> BriefSchedule {
        let restored = try JSONDecoder().decode(BriefSchedule.self, from: JSONEncoder().encode(schedule))
        XCTAssertEqual(restored, schedule)
        return restored
    }

    func testAwakeThresholdInFixedZones() throws {
        for (zone, threshold) in [
            ("Australia/Brisbane", "2026-10-07T20:58:00Z"),
            ("Australia/Sydney", "2026-10-07T19:58:00Z"),
            ("America/New_York", "2026-10-08T10:58:00Z"),
        ] {
            let calendar = try calendar(zone)
            let now = try date(threshold)
            var schedule = schedule(calendar)
            XCTAssertEqual(step(&schedule, .tick(now.addingTimeInterval(-1)), calendar: calendar), [], zone)
            let id = try start(&schedule, at: now, calendar: calendar)
            XCTAssertEqual(schedule.job?.opening, now.addingTimeInterval(120), zone)
            XCTAssertEqual(finish(&schedule, id: id, at: now.addingTimeInterval(30), calendar: calendar), [.publishBrief(jobID: id)])
            XCTAssertEqual(step(&schedule, .tick(now.addingTimeInterval(120)), calendar: calendar), [])
            _ = try restored(schedule)
        }
    }

    func testSleepAcrossOpeningCatchesUpOnlyOnceAndCoalescesMissedDays() throws {
        let calendar = try calendar()
        for wakeTime in ["2026-10-07T23:00:00Z", "2026-10-10T23:00:00Z"] {
            let before = try date("2026-10-07T20:00:00Z")
            let wake = try date(wakeTime)
            var schedule = schedule(calendar)
            schedule.lastBriefAt = before.addingTimeInterval(-86400)
            let previous = schedule.lastBriefAt
            XCTAssertEqual(step(&schedule, .sleep(before), calendar: calendar), [.keepPreviousBrief])
            XCTAssertEqual(step(&schedule, .tick(wake), calendar: calendar), [])
            XCTAssertEqual(step(&schedule, .wake(wake), calendar: calendar), [.refreshSources])
            XCTAssertEqual(schedule.lastBriefAt, previous)
            let id = try XCTUnwrap(schedule.job?.id)
            for event in [ScheduleEvent.tick(wake), .wake(wake)] {
                XCTAssertEqual(step(&schedule, event, calendar: calendar), [])
            }
            XCTAssertEqual(step(&schedule, .userRefresh(wake), calendar: calendar), [.refused(code: "already_generating")])
            _ = step(&schedule, .sourcesRefreshed(jobID: id, inputTime: wake, at: wake), calendar: calendar)
            _ = finish(&schedule, id: id, at: wake, calendar: calendar)
            XCTAssertEqual(step(&schedule, .wake(wake), calendar: calendar), [])
        }
    }

    func testLeadCrossesMidnightAndDoesNotGenerateAgainAtMidnight() throws {
        let calendar = try calendar()
        var schedule = schedule(calendar, hour: 0, minute: 1)
        let threshold = try date("2026-10-07T13:59:00Z") // 23:59 local, next opening 00:01
        // Today's brief was already produced before testing the next day's threshold.
        let morning = threshold.addingTimeInterval(-12 * 3600)
        let first = try start(&schedule, at: morning, calendar: calendar)
        _ = finish(&schedule, id: first, at: morning, calendar: calendar)
        XCTAssertEqual(step(&schedule, .tick(threshold.addingTimeInterval(-1)), calendar: calendar), [])
        let id = try start(&schedule, at: threshold, calendar: calendar)
        XCTAssertEqual(schedule.job?.opening, threshold.addingTimeInterval(120))
        _ = finish(&schedule, id: id, at: threshold.addingTimeInterval(30), calendar: calendar)
        XCTAssertEqual(step(&schedule, .tick(threshold.addingTimeInterval(60)), calendar: calendar), [])
        XCTAssertEqual(step(&schedule, .wake(threshold.addingTimeInterval(120)), calendar: calendar), [])
    }

    func testDSTGapsAndFoldsUseNextValidAndFirstOccurrence() throws {
        for (zone, hour, day, expected) in [
            ("Australia/Sydney", 2, "2026-10-03T14:00:00Z", "2026-10-03T16:00:00Z"), // gap -> 03:00
            ("Australia/Sydney", 2, "2026-04-04T13:00:00Z", "2026-04-04T15:30:00Z"), // first 02:30
            ("America/New_York", 2, "2026-03-08T05:00:00Z", "2026-03-08T07:00:00Z"), // gap -> 03:00
            ("America/New_York", 1, "2026-11-01T04:00:00Z", "2026-11-01T05:30:00Z"), // first 01:30
        ] {
            let calendar = try calendar(zone)
            var schedule = schedule(calendar, hour: hour, minute: 30)
            let opening = try date(expected)
            XCTAssertEqual(try schedule.opening(on: date(day), calendar: calendar), opening, zone)
            let threshold = opening.addingTimeInterval(-120)
            XCTAssertEqual(step(&schedule, .tick(threshold.addingTimeInterval(-1)), calendar: calendar), [], zone)
            let id = try start(&schedule, at: threshold, calendar: calendar)
            _ = finish(&schedule, id: id, at: threshold, calendar: calendar)
            XCTAssertEqual(step(&schedule, .tick(opening.addingTimeInterval(3600)), calendar: calendar), [], zone)
        }
    }

    func testSevenAMAcrossDSTDaysAndNextCalendarDay() throws {
        for (zone, before, after) in [
            ("Australia/Sydney", "2026-10-02T20:58:00Z", "2026-10-03T19:58:00Z"),
            ("Australia/Sydney", "2026-04-03T19:58:00Z", "2026-04-04T20:58:00Z"),
            ("America/New_York", "2026-03-07T11:58:00Z", "2026-03-08T10:58:00Z"),
            ("America/New_York", "2026-10-31T10:58:00Z", "2026-11-01T11:58:00Z"),
        ] {
            let calendar = try calendar(zone)
            var schedule = schedule(calendar)
            let firstTime = try date(before)
            let first = try start(&schedule, at: firstTime, calendar: calendar)
            _ = finish(&schedule, id: first, at: firstTime, calendar: calendar)
            let next = try date(after)
            XCTAssertEqual(step(&schedule, .tick(next.addingTimeInterval(-1)), calendar: calendar), [])
            _ = try start(&schedule, at: next, calendar: calendar)
        }
    }

    func testTravelRecalculatesButDoesNotRepeatCompletedCivilDate() throws {
        let brisbane = try calendar()
        let newYork = try calendar("America/New_York")
        let now = try date("2026-10-08T10:00:00Z")
        var schedule = schedule(brisbane)
        XCTAssertEqual(step(&schedule, .timeZoneChanged(newYork.timeZone, now), calendar: brisbane), []) // 06:00 local
        let threshold = try date("2026-10-08T10:58:00Z")
        let id = try start(&schedule, at: threshold, calendar: brisbane)
        _ = finish(&schedule, id: id, at: threshold, calendar: brisbane)
        XCTAssertEqual(step(&schedule, .timeZoneChanged(brisbane.timeZone, threshold), calendar: brisbane), [])
        XCTAssertEqual(schedule.timeZone, brisbane.timeZone)
        _ = try restored(schedule)
        // Moving to a new civil date catches up that date, without overlapping a running job.
        let next = try date("2026-10-08T23:00:00Z")
        XCTAssertEqual(step(&schedule, .tick(next), calendar: brisbane), [.refreshSources])
        let reserved = schedule.job
        XCTAssertEqual(step(&schedule, .timeZoneChanged(newYork.timeZone, next), calendar: brisbane), [])
        XCTAssertEqual(schedule.job, reserved)
    }

    func testFixedTimeZoneIgnoresTravel() throws {
        let calendar = try calendar()
        var schedule = BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: calendar.timeZone, timeZonePolicy: .fixed)
        let now = try date("2026-10-07T20:00:00Z")
        XCTAssertEqual(try step(&schedule, .timeZoneChanged(self.calendar("America/New_York").timeZone, now), calendar: calendar), [])
        XCTAssertEqual(schedule.timeZone, calendar.timeZone)
        _ = try start(&schedule, at: now.addingTimeInterval(58 * 60), calendar: calendar)
    }
}

extension BriefSchedulerTests {
    func testCrashRestorePreservesBusySlotAndResumeBacksOff() throws {
        let calendar = try calendar()
        let now = try date("2026-10-07T20:58:00Z")
        for phase in [ScheduleState.refreshing, .generating, .cancelling] {
            var schedule = schedule(calendar)
            _ = step(&schedule, .tick(now), calendar: calendar)
            let id = try XCTUnwrap(schedule.job?.id)
            if phase != .refreshing {
                _ = step(&schedule, .sourcesRefreshed(jobID: id, inputTime: now, at: now), calendar: calendar)
            }
            if phase == .cancelling {
                _ = step(&schedule, .sleep(now), calendar: calendar)
            }
            schedule = try restored(schedule)
            XCTAssertEqual(step(&schedule, .userRefresh(now), calendar: calendar), [.refused(code: "already_generating")])
            XCTAssertEqual(step(&schedule, .resume(now), calendar: calendar), [.keepPreviousBrief])
            XCTAssertEqual(schedule.state, .backoff(until: now.addingTimeInterval(60)))
            schedule = try restored(schedule)
            XCTAssertEqual(step(&schedule, .tick(now.addingTimeInterval(59)), calendar: calendar), [])
            XCTAssertEqual(step(&schedule, .tick(now.addingTimeInterval(60)), calendar: calendar), [.refreshSources])
            XCTAssertNotEqual(schedule.job?.id, id)
            XCTAssertEqual(finish(&schedule, id: id, at: now.addingTimeInterval(60), calendar: calendar), [])
        }
    }

    func testRestoredLiveJobCanCompleteWithoutResume() throws {
        let calendar = try calendar()
        let now = try date("2026-10-07T20:58:00Z")
        var schedule = schedule(calendar)
        let id = try start(&schedule, at: now, calendar: calendar)
        schedule = try restored(schedule)
        XCTAssertEqual(step(&schedule, .tick(now), calendar: calendar), [])
        XCTAssertEqual(finish(&schedule, id: id, at: now, calendar: calendar), [.publishBrief(jobID: id)])
    }

    func testFailuresKeepPreviousAndRetryWithCappedExponentialBackoff() throws {
        let calendar = try calendar()
        for outcome in [ModelJobResult.Status.failed, .timedOut, .cancelled] {
            var schedule = schedule(calendar)
            var now = try date("2026-10-07T20:58:00Z")
            let previous = now.addingTimeInterval(-86400)
            schedule.lastBriefAt = previous
            for delay: TimeInterval in [60, 120, 240, 480, 960, 1920, 3600, 3600] {
                let id = try start(&schedule, at: now, calendar: calendar)
                XCTAssertEqual(
                    step(&schedule, .jobFinished(jobID: id, outcome: outcome, duration: 200, at: now), calendar: calendar),
                    [.keepPreviousBrief]
                )
                XCTAssertEqual(schedule.lastBriefAt, previous)
                XCTAssertEqual(schedule.durations, [])
                XCTAssertEqual(schedule.state, .backoff(until: now.addingTimeInterval(delay)))
                XCTAssertEqual(step(&schedule, .tick(now.addingTimeInterval(delay - 1)), calendar: calendar), [])
                schedule = try restored(schedule)
                now = now.addingTimeInterval(delay)
            }
        }
    }

    func testWatchdogWaitsForTerminationAndIgnoresLateComplete() throws {
        let calendar = try calendar()
        let now = try date("2026-10-07T20:58:00Z")
        var schedule = schedule(calendar)
        let id = try start(&schedule, at: now, calendar: calendar)
        let deadline = now.addingTimeInterval(schedule.jobTimeout)
        XCTAssertEqual(step(&schedule, .tick(deadline), calendar: calendar), [.keepPreviousBrief, .cancelJob(jobID: id)])
        XCTAssertEqual(step(&schedule, .tick(deadline.addingTimeInterval(5000)), calendar: calendar), [])
        XCTAssertEqual(step(&schedule, .userRefresh(deadline), calendar: calendar), [.refused(code: "already_generating")])
        schedule = try restored(schedule)
        XCTAssertEqual(finish(&schedule, id: id, at: deadline, calendar: calendar), [.keepPreviousBrief])
        XCTAssertNil(schedule.lastBriefAt)
        _ = try start(&schedule, at: deadline.addingTimeInterval(60), calendar: calendar)
    }

    func testSleepDuringWorkRequestsCancellationAndWakeDoesNotOverlap() throws {
        let calendar = try calendar()
        let now = try date("2026-10-07T20:58:00Z")
        var schedule = schedule(calendar)
        let id = try start(&schedule, at: now, calendar: calendar)
        XCTAssertEqual(step(&schedule, .sleep(now), calendar: calendar), [.keepPreviousBrief, .cancelJob(jobID: id)])
        XCTAssertEqual(step(&schedule, .wake(now.addingTimeInterval(3600)), calendar: calendar), [])
        XCTAssertEqual(finish(&schedule, id: id, at: now.addingTimeInterval(3600), calendar: calendar), [.keepPreviousBrief])
        XCTAssertNil(schedule.lastBriefAt)
    }

    func testPowerDeferralRoundTripsAndResumesOnce() throws {
        let calendar = try calendar()
        let now = try date("2026-10-07T20:58:00Z")
        for (thermal, power, reason) in [(true, false, "thermal_serious"), (false, true, "low_power"), (true, true, "thermal_serious")] {
            var schedule = schedule(calendar)
            XCTAssertEqual(
                step(&schedule, .conditions(thermalSerious: thermal, lowPower: power, at: now), calendar: calendar),
                [.keepPreviousBrief, .publishDeferred(reason: reason)]
            )
            XCTAssertEqual(schedule.state, .deferred(reason: reason))
            XCTAssertNil(schedule.job)
            schedule = try restored(schedule)
            XCTAssertEqual(step(&schedule, .tick(now), calendar: calendar), [])
            XCTAssertEqual(
                step(&schedule, .conditions(thermalSerious: false, lowPower: false, at: now), calendar: calendar), [.refreshSources]
            )
            XCTAssertEqual(step(&schedule, .wake(now), calendar: calendar), [])
        }
    }

    func testManualRefreshEarlyAndWhileBusyIncludingDuplicateAcknowledgements() throws {
        let calendar = try calendar()
        let now = try date("2026-10-07T18:00:00Z") // 04:00 local
        var schedule = schedule(calendar)
        XCTAssertEqual(step(&schedule, .tick(now), calendar: calendar), [])
        XCTAssertEqual(step(&schedule, .userRefresh(now), calendar: calendar), [.refreshSources])
        let id = try XCTUnwrap(schedule.job?.id)
        for event in [ScheduleEvent.tick(now), .wake(now)] {
            XCTAssertEqual(step(&schedule, event, calendar: calendar), [])
        }
        XCTAssertEqual(step(&schedule, .userRefresh(now), calendar: calendar), [.refused(code: "already_generating")])
        XCTAssertEqual(step(&schedule, .sourcesRefreshed(jobID: "other", inputTime: now, at: now), calendar: calendar), [])
        XCTAssertEqual(
            step(&schedule, .sourcesRefreshed(jobID: id, inputTime: now, at: now), calendar: calendar),
            [.startGeneration(jobID: id)]
        )
        XCTAssertEqual(step(&schedule, .sourcesRefreshed(jobID: id, inputTime: now, at: now), calendar: calendar), [])
        XCTAssertEqual(step(&schedule, .userRefresh(now), calendar: calendar), [.refused(code: "already_generating")])
        XCTAssertEqual(finish(&schedule, id: id, at: now, calendar: calendar), [.publishBrief(jobID: id)])
        XCTAssertEqual(finish(&schedule, id: id, at: now, calendar: calendar), [])
        XCTAssertEqual(step(&schedule, .userRefresh(now), calendar: calendar), [.refreshSources])
        XCTAssertNotEqual(schedule.job?.id, id)
    }

    func testStaleAndFutureSnapshotsAreRejectedAtGenerationAndPublication() throws {
        let calendar = try calendar()
        let now = try date("2026-10-07T20:58:00Z")
        for age: TimeInterval in [901, -1] {
            var schedule = schedule(calendar)
            _ = step(&schedule, .tick(now), calendar: calendar)
            let id = try XCTUnwrap(schedule.job?.id)
            XCTAssertEqual(
                step(&schedule, .sourcesRefreshed(jobID: id, inputTime: now.addingTimeInterval(-age), at: now), calendar: calendar),
                [.keepPreviousBrief]
            )
            XCTAssertNil(schedule.lastBriefAt)
        }
        var schedule = schedule(calendar)
        _ = step(&schedule, .tick(now), calendar: calendar)
        let id = try XCTUnwrap(schedule.job?.id)
        XCTAssertEqual(
            step(&schedule, .sourcesRefreshed(jobID: id, inputTime: now.addingTimeInterval(-900), at: now), calendar: calendar),
            [.startGeneration(jobID: id)]
        )
        XCTAssertEqual(finish(&schedule, id: id, at: now.addingTimeInterval(1), calendar: calendar), [.keepPreviousBrief])
        XCTAssertNil(schedule.lastBriefAt)
    }

    func testRefreshCannotPublishAndHasDeadlineToo() throws {
        let calendar = try calendar()
        let now = try date("2026-10-07T20:58:00Z")
        for time in [now, now.addingTimeInterval(600)] {
            var schedule = schedule(calendar)
            _ = step(&schedule, .tick(now), calendar: calendar)
            let id = try XCTUnwrap(schedule.job?.id)
            XCTAssertEqual(finish(&schedule, id: id, at: time, calendar: calendar), [.keepPreviousBrief])
            XCTAssertNil(schedule.lastBriefAt)
        }
    }

    func testP95NearestRankAndHistoryBound() throws {
        let calendar = try calendar()
        for (samples, expected): ([TimeInterval], TimeInterval) in [
            ([], 120), ([10], 120), ([100], 160),
            (Array(1 ... 20).map { Double($0) * 10 }, 250),
            ([10, 20, 30, 1000], 1060),
        ] {
            let schedule = BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: calendar.timeZone, durations: samples)
            XCTAssertEqual(schedule.lead, expected)
        }
        var schedule = BriefSchedule(
            openingHour: 7, openingMinute: 0, timeZone: calendar.timeZone,
            durations: [10000] + [TimeInterval](repeating: 100, count: 20) + [.infinity, -.infinity, .nan, -1]
        )
        XCTAssertEqual(schedule.durations.count, 20)
        XCTAssertEqual(schedule.lead, 160)
        let now = try date("2026-10-07T20:58:00Z")
        let id = try start(&schedule, at: now, calendar: calendar)
        _ = finish(&schedule, id: id, at: now, calendar: calendar)
        XCTAssertEqual(schedule.durations, [TimeInterval](repeating: 100, count: 19) + [30])
        _ = try restored(schedule)
    }
}
