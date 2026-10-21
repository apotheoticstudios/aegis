@testable import Aegis
import AegisKit
import XCTest

final class AegisAppTests: XCTestCase {
    func testSourceHeadingAndExcerptReadCleanly() throws {
        var event = try XCTUnwrap(exampleSourceEvent())
        event.source = .email
        event.senderHandle = "jordan@example.com"
        event.senderContact = nil
        event.direction = .incoming
        event.title = "Invoice 1043"
        event.body = "Hi,\nthe invoice is due Friday."
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let heading = SourcePresentation.heading(event, now: event.eventTime, calendar: calendar)
        XCTAssertTrue(heading.hasPrefix("MAIL · jordan@example.com · "), heading)
        XCTAssertEqual(SourcePresentation.excerpt(event), "Invoice 1043 — Hi, the invoice is due Friday.")
        event.title = nil
        event.body = String(repeating: "x", count: 500)
        XCTAssertEqual(SourcePresentation.excerpt(event).count, 240)
        XCTAssertTrue(SourcePresentation.excerpt(event).hasSuffix("…"))
    }

    private func exampleSourceEvent() -> Event? {
        let line = [
            #"{"schema_version":"0.2","id":"ev_67d18655edf43ac7","source":"email","source_record_id":"<1043@example.com>""#,
            #","app_id":"com.apple.mail","direction":"incoming","sender":"Jordan Sample""#,
            #","sender_handle":"jordan@example.com","sender_contact":null,"recipients":[],"thread_id":"t-1""#,
            #","event_time":"2026-10-06T00:05:00Z","event_time_source":"sent","capture_time":"2026-10-06T07:00:00Z""#,
            #","title":"Invoice 1043","body":"Due Friday.","content":"complete","flags":[]"#,
            #","observations":[{"route":"mail_store","source_record_id":"<1043@example.com>""#,
            #","capture_time":"2026-10-06T07:00:00Z"}]}"#,
        ].joined()
        return try? JSONDecoder().decode(Event.self, from: Data(line.utf8))
    }

    func testTodayListsAllDayThenTimedThenRemindersAndHidesCancelled() {
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let day = Date(timeIntervalSince1970: 1_791_331_200) // 2026-10-07T00:00:00Z
        let now = day.addingTimeInterval(8 * 3600)
        func occurrence(
            _ id: String,
            _ title: String,
            from: Double,
            to: Double,
            allDay: Bool = false,
            status: CalendarOccurrence.Status = .confirmed,
            place: String? = nil
        ) -> CalendarOccurrence {
            CalendarOccurrence(
                itemID: id, occurrenceDate: nil, calendarTitle: nil, title: title,
                start: day.addingTimeInterval(from * 3600), end: day.addingTimeInterval(to * 3600), isAllDay: allDay,
                timeZone: allDay ? nil : "UTC", location: place, status: status, captureTime: now
            )
        }
        func reminder(_ id: String, _ title: String, due hours: Double?, timed: Bool = false, done: Bool = false) -> ReminderItem {
            ReminderItem(
                itemID: id, listTitle: nil, title: title,
                due: hours.map { .init(date: day.addingTimeInterval($0 * 3600), hasTime: timed, timeZone: "UTC") },
                isCompleted: done, completedAt: done ? now : nil, priority: 0, captureTime: now
            )
        }
        let rows = BriefPresentation.today(
            occurrences: [
                occurrence("2", "Lunch", from: 12, to: 13, place: "Cafe"),
                occurrence("1", "Standup", from: 9, to: 9.5),
                occurrence("3", "Holiday", from: 0, to: 24, allDay: true),
                occurrence("4", "Cancelled call", from: 15, to: 16, status: .cancelled),
                occurrence("5", "Tomorrow", from: 33, to: 34),
            ],
            reminders: [
                reminder("r1", "Bins", due: 0),
                reminder("r2", "Pay invoice", due: -48),
                reminder("r3", "Someday", due: nil),
                reminder("r4", "Call back", due: 17, timed: true),
                reminder("r5", "Done already", due: 0, done: true),
            ],
            now: now, calendar: calendar
        )
        XCTAssertEqual(rows.map(\.title), ["Holiday", "Standup", "Lunch", "Pay invoice", "Bins", "Call back"])
        XCTAssertEqual(rows.map(\.time), ["ALL DAY", "09:00–09:30", "12:00–13:00", "OVERDUE", "DUE", "17:00"])
        XCTAssertEqual(rows[2].detail, "Cafe")
        XCTAssertEqual(rows[3].kind, .overdue)
    }

    func testEveningBriefIsTheWrapUpAndTheScheduleTurnsToTomorrowAt5pm() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))
        func at(_ hour: Int, _ minute: Int = 0) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: hour, minute: minute)))
        }
        XCTAssertEqual(try BriefPresentation.title(storedAt: at(6, 58), now: at(8), calendar: calendar), "MORNING BRIEF")
        XCTAssertEqual(try BriefPresentation.title(storedAt: at(13), now: at(14), calendar: calendar), "BRIEF")
        XCTAssertEqual(try BriefPresentation.title(storedAt: at(18, 30), now: at(19), calendar: calendar), "EVENING WRAP-UP")
        XCTAssertEqual(try BriefPresentation.scheduleDay(now: at(16, 59), calendar: calendar), try calendar.startOfDay(for: at(12)))
        XCTAssertEqual(
            try BriefPresentation.scheduleDay(now: at(17), calendar: calendar),
            try calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: at(12)))
        )
    }

    func testReactorIconIsATemplateWithAGlowingVariant() throws {
        let plain = ReactorIcon.image(glowing: false), glowing = ReactorIcon.image(glowing: true)
        XCTAssertTrue(plain.isTemplate && glowing.isTemplate)
        XCTAssertEqual(plain.size, ReactorIcon.size)
        XCTAssertNotEqual(try XCTUnwrap(plain.tiffRepresentation), try XCTUnwrap(glowing.tiffRepresentation))
    }

    @MainActor func testGlowForANewUrgentBriefUntilThePanelOpens() async {
        UserDefaults.standard.removeObject(forKey: "lastSeenBrief")
        UserDefaults.standard.removeObject(forKey: "glowForUrgent")
        let now = Date()
        let model = PanelModel(service: RecordingCore(storedAt: now.addingTimeInterval(-60)))
        await model.checkForNewBrief()
        XCTAssertTrue(model.glow, "the sample brief has an urgent item the owner hasn't seen")
        await model.opened(now: now)
        XCTAssertFalse(model.glow, "opening the panel clears it")
        await model.checkForNewBrief()
        XCTAssertFalse(model.glow, "the same brief doesn't glow again")
        model.glowEnabled = false
        XCTAssertFalse(model.glow)
        UserDefaults.standard.removeObject(forKey: "lastSeenBrief")
        UserDefaults.standard.removeObject(forKey: "glowForUrgent")
    }

    @MainActor
    func testOpeningThePanelWritesAFreshBriefOnlyWhenTheLastIsOverAnHourOld() async {
        let now = Date()
        let recent = RecordingCore(storedAt: now.addingTimeInterval(-600))
        await PanelModel(service: recent).opened(now: now)
        XCTAssertFalse(recent.refreshRequested, "a 10-minute-old brief is shown as it is")
        let stale = RecordingCore(storedAt: now.addingTimeInterval(-7200))
        await PanelModel(service: stale).opened(now: now)
        XCTAssertTrue(stale.refreshRequested, "a 2-hour-old brief is refreshed when the panel opens")
    }

    @MainActor
    func testOpeningThePanelInTheTestHostNeverStartsTheWorldServer() async {
        await PanelModel(service: SampleCoreService()).opened(now: Date())
        XCTAssertTrue(WorldSidecar.isTestHost)
        do {
            _ = try await WorldSidecar().start()
            XCTFail("the test host must not start the owner's World server")
        } catch {}
    }

    func testCoreLinks() {
        XCTAssertFalse(AegisKit.version.isEmpty)
    }

    /// macOS remembers an agent's first signature, so an unsigned or ad hoc build must never register
    /// AegisCore or ModelService (ADR-0013). The test runner itself is unsigned.
    func testUnsignedBuildsNeverRegisterTheAgents() {
        XCTAssertEqual(BackgroundParts.register(team: nil), .skippedUnsigned)
    }

    func testSectionsAreUrgentThenReplyThenFYIAndSkipEmptyGroups() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        var brief = SampleCoreService.brief(now: now).brief
        brief.items.reverse()
        XCTAssertEqual(BriefPresentation.sections(brief).map(\.priority), [.urgent, .reply, .fyi])
        brief.items.removeAll { $0.priority == .reply }
        XCTAssertEqual(BriefPresentation.sections(brief).map(\.priority), [.urgent, .fyi])
    }

    @MainActor func testFilteredLoadsWithTheBriefAndNotJunkRemovesTheSender() async {
        let model = PanelModel(service: SampleCoreService())
        await model.refresh()
        let sender = try? XCTUnwrap(model.filtered.first)
        XCTAssertEqual(sender?.reason, .promotion)
        if let sender {
            await model.trust(sender)
        }
        XCTAssertTrue(model.filtered.isEmpty)
        XCTAssertEqual(BriefPresentation.reason(.appNotice), "App notice")
    }

    @MainActor func testPeopleWaitingLoadWithTheBriefAndReadInPlainWords() async {
        let model = PanelModel(service: SampleCoreService())
        await model.refresh()
        XCTAssertEqual(model.people.map(\.person.name), ["Alex Example"])
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        XCTAssertEqual(BriefPresentation.waiting(since: now.addingTimeInterval(-20 * 60), now: now), "20 min")
        XCTAssertEqual(BriefPresentation.waiting(since: now.addingTimeInterval(-3 * 3600), now: now), "3 h")
        XCTAssertEqual(BriefPresentation.waiting(since: now.addingTimeInterval(-3 * 86400), now: now), "3 d")
    }

    @MainActor func testAskShowsTheAnswerAndPlainReasonsWhenThereIsNone() async {
        let model = PanelModel(service: SampleCoreService())
        await model.ask("  What did Alex ask?  ")
        guard case let .answered(question, answer) = model.askState else { return XCTFail("the sample answers") }
        XCTAssertEqual(question, "What did Alex ask?")
        XCTAssertEqual(answer.eventIDs, ["ev_f403382210fbc3b8"])
        model.clearAnswer()
        XCTAssertEqual(model.askState, .idle)
        await model.ask("   ")
        XCTAssertEqual(model.askState, .idle, "an empty question sends nothing")
        XCTAssertEqual(BriefPresentation.askMessage("busy"), "Aegis is writing your brief. Ask again in a minute.")
        XCTAssertFalse(BriefPresentation.askMessage("anything_else").isEmpty)
    }

    @MainActor func testLearningAnIdentityRefreshesTheExistingBrief() async throws {
        let model = PanelModel(service: MemoryRefreshCore(), actions: nil)
        await model.refresh()
        let original = try XCTUnwrap(model.stored)
        await model.ask("0400 000 001 is Morgan Example")
        XCTAssertEqual(model.stored?.storedAt, original.storedAt, "the original brief did not need regeneration")
        XCTAssertEqual(model.stored?.brief.items.first?.text, "Morgan Example asked about a parcel.")
    }

    func testAPersonsItemsFoldIntoOneEntryInTheirMostUrgentSection() {
        let alex = Brief.Person(id: "contact:alex", name: "Alex Example")
        let robin = Brief.Person(id: "contact:robin", name: "Robin Example")
        let ids = ["ev_0000000000000001", "ev_0000000000000002", "ev_0000000000000003", "ev_0000000000000004"]
        let brief = Brief(
            generatedAt: Date(), windowStart: Date(), windowEnd: Date(), model: nil, items: [
                .init(text: "Bank alert.", priority: .urgent, eventIDs: [ids[0]]),
                .init(text: "Alex asked about the venue.", priority: .reply, eventIDs: [ids[1]], person: alex),
                .init(text: "Robin asked for the plan.", priority: .reply, eventIDs: [ids[2]], person: robin),
                .init(text: "Alex needs the room booked today.", priority: .urgent, eventIDs: [ids[3]], person: alex),
            ], omittedEvents: 0
        )
        let sections = BriefPresentation.sections(brief)
        XCTAssertEqual(sections.map(\.priority), [.urgent, .reply])
        XCTAssertEqual(sections[0].entries.count, 2)
        guard case let .person(person, items) = sections[0].entries[1] else { return XCTFail("Alex folds into one entry") }
        XCTAssertEqual(person, alex)
        XCTAssertEqual(items.map(\.text), ["Alex asked about the venue.", "Alex needs the room booked today."])
        guard case let .item(single) = sections[1].entries.first else { return XCTFail("Robin's single item stays an item") }
        XCTAssertEqual(single.person, robin)
    }

    func testCoverageLineKeepsNothingNewApartFromNoAccess() {
        let line = BriefPresentation.coverageLine([
            SourceCoverage(source: .messages, status: .ok, events: 5, lastSuccess: nil),
            SourceCoverage(source: .mail, status: .noData, events: 0, lastSuccess: nil),
            SourceCoverage(source: .notifications, status: .permissionDenied, events: 0, lastSuccess: nil),
        ])
        XCTAssertEqual(line, "Messages 5 new · Mail nothing new · Notifications no access")
    }

    func testWrittenSaysTodayYesterdayOrTheDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Brisbane"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 7, minute: 5)))
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 6, minute: 58)))
        let lastNight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 21, minute: 12)))
        let earlier = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 7, minute: 0)))
        XCTAssertTrue(BriefPresentation.written(morning, now: now, calendar: calendar).hasPrefix("Written today, 6:58"))
        XCTAssertTrue(BriefPresentation.written(lastNight, now: now, calendar: calendar).hasPrefix("Written yesterday, 9:12"))
        XCTAssertTrue(BriefPresentation.written(earlier, now: now, calendar: calendar).hasPrefix("Written 6 Oct"))
    }
}

/// A AegisCore stand-in that records whether a refresh was asked for.
final class RecordingCore: CoreService, @unchecked Sendable {
    private let lock = NSLock()
    private var refreshed = false
    private let storedAt: Date

    init(storedAt: Date) {
        self.storedAt = storedAt
    }

    var refreshRequested: Bool {
        lock.withLock { refreshed }
    }

    // The service fake intentionally exhausts the additive wire contract.
    // swiftlint:disable:next cyclomatic_complexity
    func handle(_ request: CoreRequest) async -> CoreResponse {
        switch request {
        case .latestBrief:
            var brief = SampleCoreService.brief(now: storedAt)
            brief.storedAt = storedAt
            return .brief(brief)
        case .status:
            return .status(CoreStatus(sources: [], lastBriefAt: storedAt, nextBriefAt: nil, generating: false))
        case .prepareModel:
            return .accepted(jobID: "warm")
        case .refreshBrief:
            lock.withLock { refreshed = true }
            return .accepted(jobID: "brief-1")
        case .sources:
            return .events([])
        case .schedule:
            return .schedule(occurrences: [], reminders: [])
        case .ask:
            return .refused(code: "busy")
        case .prep:
            return .refused(code: "busy")
        case .worldPlan:
            return .worldPlan(actions: [], say: nil)
        case .people:
            return .people([])
        case .filtered, .trustSender, .markJunk:
            return .filtered([])
        case .rules, .mute, .unmute, .vip, .unvip, .addKeyword, .removeKeyword:
            return .rules(.empty)
        case .draftReply:
            return .refused(code: "nothing_open")
        case .interpret:
            return .refused(code: "not_a_command")
        case .commitments:
            return .commitments([])
        case .done:
            return .done([])
        case .ruleSuggestions, .dismissSuggestion:
            return .ruleSuggestions([])
        case .morningRoutine, .decideRoutine, .routineDone:
            return .morningRoutine(MorningRoutine(day: Calendar.current.startOfDay(for: Date())))
        case .memories, .forgetMemory:
            return .memories([])
        case .personality, .setPersonality:
            return .personality(.standard)
        case .partialReply:
            return .partialReply("")
        case .converse:
            return .refused(code: "busy")
        case .handedOff:
            return .accepted(jobID: "handed-off")
        }
    }
}

private actor MemoryRefreshCore: CoreService {
    private var learned = false
    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    func handle(_ request: CoreRequest) async -> CoreResponse {
        switch request {
        case .ask, .converse:
            learned = true
            return .answer(Answer(text: "Remembered.", eventIDs: [], scheduleIDs: [], model: "memory", generatedAt: at))
        case .latestBrief:
            var stored = SampleCoreService.brief(now: at)
            if learned {
                stored.brief.items[0].text = "Morgan Example asked about a parcel."
            }
            return .brief(stored)
        default:
            return await SampleCoreService().handle(request)
        }
    }
}
