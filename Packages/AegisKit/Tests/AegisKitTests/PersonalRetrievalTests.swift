@testable import AegisKit
import Foundation
import XCTest

final class PersonalRetrievalTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .gmt
        return value
    }

    func testTodayMailUsesSourceAndTimeRatherThanLiteralWordsInBodies() async throws {
        let mail = prepEvent("mail", source: .email, body: "The parcel is ready.")
        let message = prepEvent("message", body: "Another parcel is ready.")
        let old = prepEvent("old-mail", age: 2 * 86400, source: .email, body: "Old parcel.")
        let store = try await prepStore([mail, message, old])
        let input = try await Ask.prepare(
            question: "What emails did I get today?", now: prepNow, calendar: calendar, store: store, contacts: nil
        )
        XCTAssertEqual(input.eventIDs, [mail.id])
        XCTAssertTrue(input.prefersGrounded)
        XCTAssertTrue(input.scheduleIDs.isEmpty)
        XCTAssertFalse(input.text.contains(message.id))
        XCTAssertFalse(input.text.contains(old.id))
    }

    func testReceivedAndSentQuestionsKeepTheirDirection() async throws {
        let incoming = prepEvent("received", source: .email, body: "The parcel is ready.")
        let outgoing = prepEvent("sent", outgoing: true, source: .email, body: "I will collect the parcel.")
        let store = try await prepStore([incoming, outgoing])
        let topic = AskSelection(
            "What did I get for lunch?",
            query: AskQuery("What did I get for lunch?", now: prepNow, calendar: calendar)
        )
        XCTAssertTrue(topic.matches(outgoing), "Getting something is not always receiving a message.")
        for (question, expected) in [
            ("What emails did I get today?", incoming.id),
            ("What did I receive today?", incoming.id),
            ("What emails did I send today?", outgoing.id),
        ] {
            let input = try await Ask.prepare(question: question, now: prepNow, calendar: calendar, store: store, contacts: nil)
            XCTAssertEqual(input.eventIDs, [expected], question)
        }
    }

    func testSpokenSenderNameIsMatchedOnlyAgainstIdentityAndConstrainsKeywordFallback() async throws {
        var correct = prepEvent("company", source: .email, body: "Invoice 1043 totals $148.")
        correct.sender = "ExampleLabs"
        correct.senderHandle = "updates@examplelabs.invalid"
        let mention = prepEvent("body-mention", handle: "other@example.com", source: .email, body: "Example Labs invoice 1043 is $999.")
        var wrongSource = correct
        wrongSource.source = .imessage
        wrongSource.sourceRecordID = "wrong-source"
        wrongSource.id = EventID.make(source: wrongSource.source, sourceRecordID: wrongSource.sourceRecordID)
        let store = try await prepStore([correct, mention, wrongSource])
        let input = try await Ask.prepare(
            question: "What did the email from Example Labs today say about invoice 1043?",
            now: prepNow, calendar: calendar, store: store, contacts: nil
        )
        XCTAssertEqual(input.eventIDs, [correct.id])
        XCTAssertFalse(input.text.contains("$999"))
        XCTAssertTrue(input.text.contains("$148"))
    }

    func testSenderClauseHonorsUniqueContactFirstNameWithoutMatchingBodyMentions() async throws {
        let correct = prepEvent("alex-mail", source: .email, body: "The parcel is ready.")
        let other = prepEvent("other-mail", handle: "other@example.com", source: .email, body: "Alex mentioned a parcel.")
        let store = try await prepStore([correct, other])
        let input = try await Ask.prepare(
            question: "Read my email from Alex today", now: prepNow, calendar: calendar, store: store, contacts: prepContacts
        )
        XCTAssertEqual(input.eventIDs, [correct.id])
    }

    func testSourceWordsUsedAsTopicsDoNotReplaceTheRequestedSource() async throws {
        let message = prepEvent("topic-message", body: "The email is ready.")
        let otherMessage = prepEvent("other-topic-message", body: "Lunch is ready.")
        let mail = prepEvent("topic-email", source: .email, body: "The email is ready.")
        let store = try await prepStore([message, otherMessage, mail])
        let topical = try await Ask.prepare(
            question: "What messages today mentioned email?", now: prepNow, calendar: calendar, store: store, contacts: nil
        )
        XCTAssertEqual(topical.eventIDs, [message.id])
        let both = try await Ask.prepare(
            question: "What emails and messages did I get today?", now: prepNow, calendar: calendar, store: store, contacts: nil
        )
        XCTAssertEqual(Set(both.eventIDs), Set([message.id, otherMessage.id, mail.id]))
    }

    func testReadRequestsWithGreetingsAndTellMeKeepTheCheckedAnswerPath() async throws {
        let event = prepEvent("alex-info", body: "The blue folder is on the library shelf.")
        let store = try await prepStore([event])
        for question in ["Tell me what Alex said today", "Hey, what did Alex say today?"] {
            let text = "{\"answer\":\"Alex said the blue folder is on the library shelf.\",\"event_ids\":[\"\(event.id)\"],\"schedule_ids\":[]}"
            let model = PrepModel(text: text)
            let core = try CoreEngine(
                store: store, collectors: [], model: model, persistence: RetrievalSchedule(),
                initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: .gmt), options: .init(modelName: "synthetic"),
                contacts: FixedContacts(index: prepContacts), calendar: calendar, clock: { prepNow }
            )
            guard case let .answer(answer) = await core.handle(.ask(question: question)) else { return XCTFail(question) }
            XCTAssertEqual(answer.eventIDs, [event.id], question)
            XCTAssertEqual(model.lastJob?.system, Ask.systemPrompt())
        }
        XCTAssertFalse(Chat.isRequestToAct("Please tell me what Alex said"))
        for command in ["Tell Alex I'm late", "Send the email to Alex", "Delete my emails today", "Tell me to call Alex"] {
            XCTAssertTrue(Chat.isRequestToAct(command), command)
        }
    }

    func testLateEvidenceAndIncompleteSourceAreVisibleWithoutPretendingToHaveTheWholeBody() async throws {
        var event = prepEvent(
            "late-fact", source: .email,
            body: String(repeating: "Invented introductory text. ", count: 180) + "Invoice 1043 totals $148."
        )
        event.content = .preview
        event.flags = [.truncated]
        let store = try await prepStore([event])
        let input = try await Ask.prepare(
            question: "What was the amount for invoice 1043 today?", now: prepNow, calendar: calendar, store: store, contacts: nil
        )
        XCTAssertEqual(input.eventIDs, [event.id])
        XCTAssertTrue(input.text.contains("1043 totals $148"))
        XCTAssertTrue(input.text.contains("body excerpt"))
        XCTAssertTrue(input.text.contains("source text incomplete"))
        XCTAssertLessThan(input.text.unicodeScalars.count, 8000)
        XCTAssertTrue(AskQuery("invoice 1043", now: prepNow, calendar: calendar).keywords.contains("1043"))
    }

    func testWeekdayTodayAndExplicitLastNextAreDifferentAndPastWhenStaysPast() throws {
        let monday = try XCTUnwrap(ContractTime.parse("2026-10-19T09:00:00Z"))
        for (text, expected) in [
            ("What did Alex say Monday?", "2026-10-19T00:00:00Z"),
            ("When did Alex email last Monday?", "2026-10-12T00:00:00Z"),
            ("When is the meeting next Monday?", "2026-10-26T00:00:00Z"),
        ] {
            XCTAssertEqual(AskQuery(text, now: monday, calendar: calendar).calendarWindow.start, ContractTime.parse(expected), text)
        }
        let wednesday = try XCTUnwrap(ContractTime.parse("2026-10-21T09:00:00Z"))
        XCTAssertEqual(
            AskQuery("When did Alex email Monday?", now: wednesday, calendar: calendar).messages.start,
            ContractTime.parse("2026-10-19T00:00:00Z")
        )
    }

    func testOverviewPagesPastOneThousandRecordsAndKeepsTheNewestEvidence() async throws {
        let events = (0 ..< 1100).map { prepEvent("page-\($0)", age: Double($0 + 1), source: .email, body: "Invented record \($0).") }
        let store = try await prepStore(events)
        let input = try await Ask.prepare(
            question: "What emails did I get today?", now: prepNow, calendar: calendar, store: store, contacts: nil
        )
        XCTAssertEqual(input.eventIDs.first, events[0].id)
        XCTAssertTrue(Set(input.eventIDs).isSubset(of: Set(events.prefix(25).map(\.id))))
        XCTAssertLessThan(input.text.unicodeScalars.count, 8000)
        XCTAssertTrue(input.text.contains("not a complete inbox or day"))
    }

    func testReadQueriesDoNotBecomeGeneralKnowledgeAndMissingRecordsDoNotClaimAnEmptyInbox() async throws {
        let empty = MemoryStore()
        let input = try await Ask.prepare(
            question: "Read my email from Example Labs today", now: prepNow, calendar: calendar, store: empty, contacts: nil
        )
        XCTAssertTrue(input.isEmpty)
        XCTAssertNotNil(input.directAnswer)
        XCTAssertFalse(input.directAnswer?.contains("no emails") ?? true)
        for question in ["Explain how email encryption works", "What is the best email app?", "Send an email today"] {
            let selection = AskSelection(question, query: AskQuery(question, now: prepNow, calendar: calendar))
            XCTAssertNil(selection.source, question)
        }
    }
}

private struct RetrievalSchedule: SchedulePersistence {
    func load() throws -> BriefSchedule? {
        nil
    }

    func save(_: BriefSchedule) throws {}
}
