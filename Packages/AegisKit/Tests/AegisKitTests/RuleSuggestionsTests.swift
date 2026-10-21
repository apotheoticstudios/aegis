@testable import AegisKit
import Foundation
import XCTest

final class RuleSuggestionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .gmt
        return value
    }

    private func event(
        _ id: String, at: Date, handle: String = "alex@example.com", outgoing: Bool = false,
        thread: String? = "example-thread", contact: String? = nil, source: Event.Source = .imessage
    ) -> Event {
        Event(
            source: source, sourceRecordID: id, appID: source == .notification ? "com.apple.Calendar" : nil,
            sender: outgoing ? "me" : "Example Alex", threadID: thread, eventTime: at,
            eventTimeSource: outgoing ? .sent : .received, captureTime: at, title: nil, body: "Example fixture",
            content: .complete, observations: [.init(
                route: source.routes.sorted { $0.rawValue < $1.rawValue }[0],
                sourceRecordID: id,
                captureTime: at
            )],
            direction: outgoing ? .outgoing : .incoming, senderHandle: outgoing ? nil : handle,
            recipients: outgoing ? [handle] : [], senderContact: contact.map { .init(id: $0, name: "Example Alex") }
        )
    }

    private func exchanges(_ count: Int, handle: String = "alex@example.com", at end: Date? = nil) -> [Event] {
        let end = end ?? now
        return (0 ..< count).flatMap { index in
            let time = end.addingTimeInterval(Double(index - count) * 3600)
            return [
                event("in-\(handle)-\(index)", at: time, handle: handle),
                event("out-\(handle)-\(index)", at: time.addingTimeInterval(600), handle: handle, outgoing: true),
            ]
        }
    }

    private func ignored(
        _ count: Int,
        handle: String = "store@example.com",
        source: Event.Source = .email,
        at end: Date? = nil
    ) -> [Event] {
        let end = end ?? now
        return (0 ..< count).map { event(
            "ignored-\(handle)-\($0)",
            at: end.addingTimeInterval(Double($0 - count) * 3600),
            handle: handle,
            thread: "thread-" + handle,
            source: source
        ) }
    }

    private func compute(_ events: [Event], rules: OwnerRules = .empty, at time: Date? = nil) -> [RuleSuggestion] {
        RuleSuggestions.compute(events: events, rules: rules, now: time ?? now, calendar: calendar)
    }

    func testVIPNeedsFiveDistinctQuickRepliesAndNeverAppliesItself() throws {
        let rules = OwnerRules.empty
        XCTAssertTrue(compute(exchanges(4), rules: rules).isEmpty)
        let result = try XCTUnwrap(compute(exchanges(5), rules: rules).first)
        XCTAssertEqual(result.kind, .vip)
        XCTAssertEqual(result.personID, "handle:alex@example.com")
        XCTAssertEqual(result.evidenceCount, 5)
        XCTAssertTrue(result.reason.contains("within 15 minutes 5 times"))
        XCTAssertEqual(rules, .empty)
        XCTAssertTrue(exchanges(5).allSatisfy { $0.validate().isEmpty })
    }

    func testExistingVIPMutedAndJunkAreNeverSuggested() {
        let events = exchanges(5)
        XCTAssertTrue(compute(events, rules: OwnerRules(vip: ["handle:alex@example.com": "Example Alex"])).isEmpty)
        XCTAssertTrue(compute(events, rules: OwnerRules(muted: ["handle:alex@example.com": "Example Alex"])).isEmpty)
        XCTAssertTrue(compute(events, rules: OwnerRules(junk: ["alex@example.com"])).isEmpty)
    }

    func testContactIDsAndEmptyNamesRemainStableAndAlreadyVIPIsExcluded() throws {
        var events = exchanges(5)
        for index in stride(from: 0, to: events.count, by: 2) {
            events[index].senderContact = .init(id: "example-alex", name: "")
        }
        let result = try XCTUnwrap(compute(events).first)
        XCTAssertEqual(result.personID, "contact:example-alex")
        XCTAssertEqual(result.name, "alex@example.com")
        XCTAssertEqual(compute(events), compute(Array(events.reversed())))
        XCTAssertTrue(compute(events, rules: OwnerRules(vip: [result.personID: result.name])).isEmpty)
    }

    func testFortnightIncludesItsExactStartButExcludesOlderIncomingEvidence() throws {
        let start = try XCTUnwrap(calendar.date(byAdding: .day, value: -14, to: now))
        var events = exchanges(5)
        events[0].eventTime = start
        events[1].eventTime = start.addingTimeInterval(600)
        XCTAssertEqual(compute(events).first?.evidenceCount, 5)
        events[0].eventTime = start.addingTimeInterval(-1)
        XCTAssertTrue(compute(events).isEmpty)
    }

    func testReplyWindowIsStrictlyAfterAndAtMostFifteenMinutes() {
        for delay in [0.0, 901.0] {
            var events = exchanges(5)
            for index in stride(from: 1, to: events.count, by: 2) {
                events[index].eventTime = events[index - 1].eventTime.addingTimeInterval(delay)
            }
            XCTAssertTrue(compute(events).isEmpty)
        }
        var boundary = exchanges(5)
        for index in stride(from: 1, to: boundary.count, by: 2) {
            boundary[index].eventTime = boundary[index - 1].eventTime.addingTimeInterval(900)
        }
        XCTAssertEqual(compute(boundary).first?.evidenceCount, 5)
    }

    func testOneReplyToABurstAndDuplicateRecordsCannotBecomeFiveOccasions() {
        let incoming = (0 ..< 8).map { event("burst-\($0)", at: now.addingTimeInterval(Double($0 - 20))) }
        let reply = event("one-reply", at: now, outgoing: true)
        XCTAssertTrue(compute(incoming + Array(repeating: reply, count: 10)).isEmpty)
        XCTAssertTrue(compute(Array(repeating: incoming[0], count: 8)).isEmpty)
    }

    func testDistinctRepliesCanPairAcrossABurstWithoutDoubleCounting() {
        let received = (0 ..< 5).map { event("burst-in-\($0)", at: now.addingTimeInterval(Double($0 - 30))) }
        let sent = (0 ..< 5).map { event("burst-out-\($0)", at: now.addingTimeInterval(Double($0 - 20)), outgoing: true) }
        XCTAssertEqual(compute(received + sent).first?.evidenceCount, 5)
    }

    func testRepliesCanMatchAnotherThreadForSamePersonButNeverCollidingSourceThreads() {
        var direct = exchanges(5)
        for index in stride(from: 1, to: direct.count, by: 2) {
            direct[index].threadID = "different-thread"
        }
        XCTAssertEqual(compute(direct).first?.kind, .vip)
        var wrong = exchanges(5)
        for index in stride(from: 1, to: wrong.count, by: 2) {
            wrong[index].source = .email
            wrong[index].recipients = ["other@example.com"]
        }
        XCTAssertTrue(compute(wrong).isEmpty)
    }

    func testGroupRepliesSuggestTheGroupAndNotEachMember() throws {
        var events = exchanges(5)
        for index in events.indices {
            events[index].threadID = "iMessage;+;example-group"
            events[index].title = "Example Group"
        }
        let result = try XCTUnwrap(compute(events).first)
        XCTAssertEqual(result.personID, "group:iMessage;+;example-group")
        XCTAssertEqual(result.name, "Example Group")
        XCTAssertEqual(result.evidenceCount, 5)
    }

    func testMuteNeedsEightIgnoredMessagesAndExcludesContactsAndAnyOwnerReplies() throws {
        XCTAssertTrue(compute(ignored(7)).isEmpty)
        let events = ignored(8)
        let result = try XCTUnwrap(compute(events).first)
        XCTAssertEqual(result.kind, .mute)
        XCTAssertEqual(result.personID, "handle:store@example.com")
        XCTAssertEqual(result.evidenceCount, 8)
        XCTAssertFalse(result.reason.contains("opened"))
        var known = events
        known[0].senderContact = .init(id: "example-store", name: "Example Store")
        XCTAssertTrue(compute(known).isEmpty)
        let reply = event("old-reply", at: now.addingTimeInterval(-10 * 86400), handle: "store@example.com", outgoing: true, source: .email)
        XCTAssertTrue(compute(events + [reply]).isEmpty)
        for rules in [
            OwnerRules(vip: [result.personID: result.name]),
            OwnerRules(muted: [result.personID: result.name]),
            OwnerRules(junk: ["store@example.com"]),
        ] {
            XCTAssertTrue(compute(events, rules: rules).isEmpty)
        }
    }

    func testOwnerSystemNotificationsFutureAndOldRecordsAreExcluded() {
        XCTAssertTrue(compute(ignored(8, source: .notification)).isEmpty)
        let old = calendar.date(byAdding: .day, value: -15, to: now) ?? now
        XCTAssertTrue(compute(ignored(8, at: old)).isEmpty)
        XCTAssertTrue(compute(ignored(8, at: now.addingTimeInterval(15 * 86400))).isEmpty)
        var owner = event("owner", at: now.addingTimeInterval(-1), handle: "store@example.com", outgoing: true, source: .email)
        owner.senderHandle = "store@example.com"
        XCTAssertTrue(compute(ignored(8) + [owner]).isEmpty)
    }

    func testKnownPersonInThirdPartyNotificationsCanBeVIPButSystemAppsCannot() {
        var events = exchanges(5)
        for index in stride(from: 0, to: events.count, by: 2) {
            events[index].source = .notification
            events[index].appID = "com.example.chat"
            events[index].senderContact = .init(id: "example-alex", name: "Example Alex")
        }
        XCTAssertEqual(compute(events).first?.personID, "contact:example-alex")
        for index in stride(from: 0, to: events.count, by: 2) {
            events[index].appID = "com.apple.Calendar"
        }
        XCTAssertTrue(compute(events).isEmpty)
    }

    func testAtMostThreeStrongestWithDeterministicTieOrder() {
        let events = ignored(9, handle: "a@example.com") + ignored(10, handle: "b@example.com")
            + ignored(10, handle: "c@example.com") + ignored(12, handle: "d@example.com")
        let results = compute(events)
        XCTAssertEqual(results.map(\.personID), ["handle:d@example.com", "handle:b@example.com", "handle:c@example.com"])
        XCTAssertEqual(results, compute(Array(events.reversed())))
    }

    func testDismissalHidesOnlyItsKindUntilTheThirtyDayBoundary() throws {
        let expiry = try XCTUnwrap(calendar.date(byAdding: .day, value: 30, to: now))
        let rules = OwnerRules(suggestionDismissals: [.init(personID: "handle:alex@example.com", kind: .vip, expiresAt: expiry)])
        XCTAssertTrue(compute(exchanges(5), rules: rules).isEmpty)
        let before = expiry.addingTimeInterval(-1)
        XCTAssertTrue(compute(exchanges(5, at: before), rules: rules, at: before).isEmpty)
        XCTAssertEqual(compute(exchanges(5, at: expiry), rules: rules, at: expiry).first?.kind, .vip)
        XCTAssertEqual(compute(ignored(8, handle: "alex@example.com"), rules: rules).first?.kind, .mute)
    }

    func testOldOwnerRulesAndNewIPCContractsRoundTrip() throws {
        let old = Data(#"{"junk":[],"trusted":[],"muted":{}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(OwnerRules.self, from: old).suggestionDismissals, [])
        for request in [
            CoreRequest.ruleSuggestions,
            .dismissSuggestion(personID: "contact:example-alex", kind: .vip),
            .dismissSuggestion(personID: "handle:store@example.com", kind: .mute),
        ] {
            XCTAssertEqual(try IPCCoding.decode(CoreRequest.self, from: IPCCoding.encode(request)), request)
        }
        let response = CoreResponse.ruleSuggestions(compute(exchanges(5)))
        XCTAssertEqual(try IPCCoding.decode(CoreResponse.self, from: IPCCoding.encode(response)), response)
    }

    func testEngineDismissalPersistsWithoutApplyingAndAcceptUsesExistingRequests() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rule-suggestion-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = OwnerRulesFile(url: folder.appendingPathComponent("rules.json"))
        let store = MemoryStore()
        try await store.ingest(CollectionBatch(
            source: .messages,
            status: .init(ok: true, code: .ok),
            events: exchanges(5),
            checkpoint: nil
        ))
        let time = now
        func engine(_ persistence: any OwnerRulesPersistence) throws -> CoreEngine {
            try CoreEngine(
                store: store,
                collectors: [],
                model: CitingModel(),
                persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
                initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: .gmt),
                options: .init(modelName: "synthetic"),
                rules: persistence,
                calendar: calendar,
                clock: { time }
            )
        }
        let core = try engine(file)
        let initial = await core.handle(.ruleSuggestions)
        XCTAssertEqual(initial, .ruleSuggestions(compute(exchanges(5))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        let dismissed = await core.handle(.dismissSuggestion(personID: "handle:alex@example.com", kind: .vip))
        XCTAssertEqual(dismissed, .ruleSuggestions([]))
        let saved = try file.load()
        XCTAssertTrue(saved.vip.isEmpty && saved.muted.isEmpty)
        XCTAssertEqual(saved.suggestionDismissals.first?.expiresAt, calendar.date(byAdding: .day, value: 30, to: now))
        let restarted = try engine(file)
        let restored = await restarted.handle(.ruleSuggestions)
        XCTAssertEqual(restored, .ruleSuggestions([]))
        let invalid = await core.handle(.dismissSuggestion(personID: "person:example", kind: .vip))
        XCTAssertEqual(invalid, .refused(code: "bad_person"))
        let failing = try engine(RefusingSuggestionRules())
        let refused = await failing.handle(.dismissSuggestion(personID: "handle:alex@example.com", kind: .vip))
        XCTAssertEqual(refused, .refused(code: "rules_unwritable"))
        let unchanged = await failing.handle(.ruleSuggestions)
        XCTAssertEqual(unchanged, initial)
        let accepted = await core.handle(.vip(personID: "handle:alex@example.com", name: "Example Alex"))
        guard case let .rules(updated) = accepted else { return XCTFail("Expected saved VIP") }
        XCTAssertNotNil(updated.vip["handle:alex@example.com"])
    }

    func testAcceptedEmailHandleRulesAffectVisibilityAndPriority() {
        let event = event("email", at: now, source: .email)
        var rules = OwnerRules.empty
        XCTAssertTrue(rules.prioritise("handle:alex@example.com", name: "Example Alex"))
        XCTAssertTrue(rules.isVIP(event))
        XCTAssertTrue(rules.mute("handle:alex@example.com", name: "Example Alex"))
        XCTAssertEqual(rules.hide(event, contacts: [:]), .muted)
    }
}

private struct RefusingSuggestionRules: OwnerRulesPersistence {
    func load() throws -> OwnerRules {
        .empty
    }

    func save(_: OwnerRules) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
