@testable import AegisKit
import Foundation
import XCTest

@MainActor
final class OwnerMemoryTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("owner-memory-" + UUID().uuidString)

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func engine(
        store: MemoryStore = MemoryStore(), model: any ModelClient = RecordingModel(),
        contacts: ContactIndex? = nil, failing: Bool = false
    ) throws -> CoreEngine {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let memory: any MemoryPersistence = failing ? UnwritableMemory() : MemoryFile(url: folder.appendingPathComponent("memory.json"))
        return try CoreEngine(
            store: store, collectors: [], model: model,
            persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
            initial: BriefSchedule(openingHour: 3, openingMinute: 0, timeZone: .gmt),
            options: .init(modelName: "synthetic"), contacts: FixedContacts(index: contacts),
            memory: memory, clock: { prepNow }
        )
    }

    func testPhoneNormalizationAndEmailAliases() throws {
        for phone in ["0400 000 001", "+61 400 000 001", "61400000001", "(04) 0000 0001"] {
            let alias = try XCTUnwrap(SenderAlias.parse(phone + " is Morgan Example"))
            XCTAssertEqual(alias.key, "phone:61400000001")
            XCTAssertEqual(alias.name, "Morgan Example")
        }
        XCTAssertEqual(SenderAlias.parse("Morgan Example's email is Morgan@Example.COM")?.key, "email:morgan@example.com")
        XCTAssertEqual(SenderAlias.parse("mailto:Morgan+tag@example.com belongs to Morgan Example")?.key, "email:morgan+tag@example.com")
        for text in [
            "123 is Morgan",
            "0400 000 001 is not Morgan",
            "Did 0400 000 001 say Morgan",
            "The email says 0400 000 001 is Morgan",
        ] {
            XCTAssertNil(SenderAlias.parse(text), text)
        }
    }

    func testAutoFactsAndIdentitiesSurviveRestartAndCorrection() async throws {
        let core = try engine()
        for text in ["0400 000 001 is Morgan Example", "My favourite colour is blue", "Example Sam is my brother"] {
            guard case let .answer(answer) = await core.handle(.ask(question: text)) else { return XCTFail("Expected acknowledgement") }
            XCTAssertEqual(answer.model, "memory")
        }
        let restarted = try engine()
        guard case let .answer(answer) = await restarted.handle(.ask(question: "Who is +61 400 000 001?")) else {
            return XCTFail("Expected remembered owner")
        }
        XCTAssertEqual(answer.text, "That belongs to Morgan Example.")
        guard case let .answer(fact) = await restarted.handle(.ask(question: "What's my favourite colour?")) else {
            return XCTFail("Expected remembered fact")
        }
        XCTAssertEqual(fact.text, "Your favourite colour is blue.")
        guard case let .answer(person) = await restarted.handle(.ask(question: "Who is Example Sam?")) else {
            return XCTFail("Expected relationship")
        }
        XCTAssertEqual(person.text, "Example Sam is your brother.")
        _ = await restarted.handle(.ask(question: "Actually, +61 400 000 001 is Taylor Sample"))
        let corrected = try engine()
        let correctedIndex = await corrected.contactIndex()
        let index = try XCTUnwrap(correctedIndex)
        guard case let .match(contact) = index.resolve(handle: "0400000001") else { return XCTFail("Expected corrected identity") }
        XCTAssertEqual(contact.name, "Taylor Sample")
        guard case let .memories(notes) = await corrected.handle(.memories) else { return XCTFail("Expected notes") }
        XCTAssertEqual(notes.count, 3, "a correction replaces the old mapping")
        _ = await corrected.handle(.ask(question: "Forget 0400 000 001"))
        let forgotten = try engine()
        let noIndex = await forgotten.contactIndex()
        XCTAssertNil(noIndex)
    }

    func testSeveralCompatibleFactsAboutOnePersonAreRetained() {
        var book = MemoryBook.empty
        _ = book.remember("Example Sam is my brother", now: prepNow)
        _ = book.remember("Example Sam is a doctor", now: prepNow)
        XCTAssertEqual(book.notes.count, 2)
        XCTAssertEqual(book.directAnswer(to: "Who is Example Sam?", now: prepNow), "Example Sam is your brother.")
    }

    func testCorrectionOverridesContactsWithoutMergingEqualNames() async throws {
        let contacts = ContactIndex([
            .init(id: "wrong", displayName: "Wrong Example", phones: ["0400000001"]),
            .init(id: "one", displayName: "Morgan Example", phones: ["0400000002"]),
            .init(id: "two", displayName: "Morgan Example", phones: ["0400000003"]),
        ])
        let core = try engine(contacts: contacts)
        _ = await core.handle(.ask(question: "0400000001 is Morgan Example"))
        let currentIndex = await core.contactIndex()
        let index = try XCTUnwrap(currentIndex)
        guard case let .match(contact) = index.resolve(handle: "0400000001") else { return XCTFail("Expected override") }
        XCTAssertEqual(contact.name, "Morgan Example")
        let privateNames = await core.contactNames()
        XCTAssertTrue(privateNames.contains("Morgan Example"))
        XCTAssertTrue(privateNames.contains("Wrong Example"))
        XCTAssertNotEqual(contact.id, "one")
        XCTAssertNotEqual(contact.id, "two")
        XCTAssertTrue(index.people(mentionedIn: "What did Morgan Example say?").ambiguous)
        _ = await core.handle(.ask(question: "Forget 0400000001"))
        let restoredIndex = await core.contactIndex()
        let restored = try XCTUnwrap(restoredIndex)
        XCTAssertEqual(restored.resolve(handle: "0400000001"), .match(.init(id: "wrong", name: "Wrong Example")))
    }

    func testBriefAndSpokenInputsUseTheRememberedSenderNotABodyMention() async throws {
        let first = prepEvent("first", age: 100, handle: "+61 400 000 001", body: "Can you collect the parcel for Taylor Sample?")
        let other = prepEvent("other", age: 60, handle: "+61 400 000 002", body: "Taylor Sample is here.")
        let store = try await prepStore([first, other])
        let model = RecordingModel()
        let core = try engine(store: store, model: model)
        _ = await core.handle(.ask(question: "0400 000 001 is Morgan Example"))
        guard case let .events(named) = await core.handle(.sources(ids: [first.id, other.id])) else { return XCTFail("Expected sources") }
        XCTAssertEqual(named.first { $0.id == first.id }?.senderContact?.name, "Morgan Example")
        XCTAssertNil(named.first { $0.id == other.id }?.senderContact)
        guard case .accepted = await core.handle(.refreshBrief(reason: .user)) else { return XCTFail("Expected refresh") }
        await core.settle()
        XCTAssertTrue(model.lastInput?.contains("from Morgan Example") == true)
        let brief = try await store.latestBrief()
        XCTAssertNotNil(brief)
        _ = await core.handle(.ask(question: "What did Morgan Example say about the parcel?"))
        XCTAssertTrue(model.lastInput?.contains("Morgan Example asked you:") == true)
        XCTAssertFalse(model.lastInput?.contains(other.id) == true)
        guard case let .memories(notes) = await core.handle(.memories) else { return XCTFail("Expected notes") }
        XCTAssertEqual(notes.count, 1, "collected messages and model replies never become memories")
    }

    func testExistingBriefIsCorrectedFromItsSourcesImmediately() async throws {
        let event = prepEvent("old-label", handle: "0400000001", body: "Can you collect the parcel?")
        let store = try await prepStore([event])
        let old = try testBrief([.init(text: "Wrong Example asked about the parcel.", priority: .reply, eventIDs: [event.id])])
        try await store.saveBrief(.init(brief: old, inputRevision: "synthetic", coverage: [], storedAt: prepNow))
        let core = try engine(store: store)
        _ = await core.handle(.ask(question: "0400000001 is Morgan Example"))
        guard case let .brief(shown?) = await core.handle(.latestBrief) else { return XCTFail("Expected brief") }
        XCTAssertEqual(shown.brief.items.first?.text, "Morgan Example asked: “Can you collect the parcel?”")
        XCTAssertEqual(shown.brief.items.first?.eventIDs, [event.id])
        XCTAssertEqual(shown.brief.items.first?.person?.name, "Morgan Example")
        let saved = try await store.latestBrief()
        XCTAssertEqual(saved?.brief, old, "a view correction preserves the original model draft")
    }

    func testUnmatchedNamesSurviveWhenContactsIsUnavailable() async throws {
        var known = prepEvent("known", handle: "+61 400 000 002")
        known.senderContact = .init(id: "known", name: "Taylor Sample")
        let core = try engine()
        _ = await core.handle(.ask(question: "0400000001 is Morgan Example"))
        let named = await core.named([known])
        XCTAssertEqual(named.first?.senderContact, known.senderContact)
    }

    func testQuestionsQuotationsAndTransientChatterDoNotBecomeFacts() {
        for text in [
            "Is 0400 000 001 Morgan Example?", "0400000001 is Morgan Example?", "If 0400000001 is Morgan Example",
            "The email says 0400000001 is Morgan Example", "\"0400000001 is Morgan Example\"", "I'm tired",
            "Can you send the report", "Hey Aegis, what's up?", "Have they sent the report", "Explain what a contact is",
        ] {
            XCTAssertNil(MemoryCommand.statedFact(text), text)
        }
    }

    func testOrdinaryFactsDoNotRequireASpecificOpeningPhrase() {
        for statement in [
            "On Fridays I work at Example Office",
            "For my birthday I would like a book",
            "Example Sam works at Example Clinic",
        ] {
            XCTAssertEqual(MemoryCommand.statedFact(statement), statement)
        }
    }

    func testLongSavedFactsStillProduceAValidMemoryListAnswer() async throws {
        let core = try engine()
        for index in 0 ..< 3 {
            _ = await core.handle(.ask(question: "My example fact \(index) is " + String(repeating: "x", count: 450)))
        }
        guard case let .answer(answer) = await core.handle(.ask(question: "What do you remember?")) else {
            return XCTFail("Expected memory list")
        }
        XCTAssertTrue(answer.validate().isEmpty)
        guard case let .memories(notes) = await core.handle(.memories) else { return XCTFail("Expected notes") }
        XCTAssertEqual(notes.count, 3)
        XCTAssertTrue(notes.allSatisfy { $0.text.count > 450 }, "only the spoken preview is shortened")
    }

    func testWriteFailureIsReportedAndCannotActivateAnIdentity() async throws {
        let core = try engine(failing: true)
        guard case let .answer(answer) = await core.handle(.ask(question: "0400000001 is Morgan Example")) else {
            return XCTFail("Expected failure explanation")
        }
        XCTAssertTrue(answer.text.contains("couldn't save"))
        XCTAssertFalse(answer.text.contains("I'll remember"))
        let noIndex = await core.contactIndex()
        XCTAssertNil(noIndex)
        guard case let .memories(notes) = await core.handle(.memories) else { return XCTFail("Expected notes") }
        XCTAssertTrue(notes.isEmpty)
    }
}

private struct UnwritableMemory: MemoryPersistence {
    func load() throws -> MemoryBook {
        .empty
    }

    func save(_: MemoryBook) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
