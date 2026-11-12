@testable import Aegis
import AegisKit
import XCTest

/// ADR-0038 stage 2: Claude's read tools fetch from AegisCore and send only what the owner's switches allow.
final class ClaudeReadsTests: XCTestCase {
    private let all = Set(ClaudeTools.Category.allCases)

    func testRecentItemsFollowTheSwitches() async {
        let reads = ClaudeReads(service: FixtureCore())
        let everything = await reads.fetch(.recentItems(limit: 10), enabled: all)
        XCTAssertEqual(everything.counts, [.messages: 1, .mail: 1, .notifications: 1])
        let noMail = await reads.fetch(.recentItems(limit: 10), enabled: all.subtracting([.mail]))
        XCTAssertFalse(noMail.text.contains("example plan"))
        let off = await reads.fetch(.recentItems(limit: 10), enabled: [.calendar])
        XCTAssertTrue(off.isError)
    }

    /// A brief item goes only when AegisCore confirms each cited item's source and the owner has it on.
    func testTheBriefIsFilteredByWhatEachItemCites() async {
        let reads = ClaudeReads(service: FixtureCore())
        let brief = await reads.fetch(.brief, enabled: all.subtracting([.mail]))
        XCTAssertTrue(brief.text.contains("Call Alex"))
        XCTAssertFalse(brief.text.contains("Review the plan"))
        XCTAssertFalse(brief.text.contains("Unknown"))
        XCTAssertEqual(brief.counts, [.messages: 1])
    }

    func testSwitchesAreKeptOnTheMac() {
        XCTAssertEqual(ClaudeReads.enabled, all, "all on until switched off")
        ClaudeReads.enabled = [.calendar, .memory]
        XCTAssertEqual(ClaudeReads.enabled, [.calendar, .memory])
        ClaudeReads.enabled = all
    }
}

/// The sample's three recent items, found again by ID, and a brief citing them.
actor FixtureCore: CoreService {
    let events = SampleCoreService.recentEvents(now: Date())

    func handle(_ request: CoreRequest) async -> CoreResponse {
        switch request {
        case .recentEvents: return .events(events)
        case let .sources(ids): return .events(events.filter { ids.contains($0.id) })
        case .people:
            return .people([PersonWaiting(
                person: .init(id: "contact:1", name: "Alex Example"), waitingSince: Date(), questions: 1, latest: "Call about Saturday?",
                eventIDs: [events[0].id]
            )])
        case .latestBrief:
            let brief = Brief(
                generatedAt: Date(), windowStart: Date(), windowEnd: Date(), model: nil, items: [
                    .init(text: "Call Alex about Saturday", priority: .urgent, eventIDs: [events[0].id]),
                    .init(text: "Review the plan", priority: .urgent, eventIDs: [events[1].id]),
                    .init(text: "Unknown", priority: .urgent, eventIDs: ["ev_missing"]),
                ], omittedEvents: 0
            )
            return .brief(StoredBrief(brief: brief, inputRevision: "r", coverage: [], storedAt: Date()))
        default: return await SampleCoreService().handle(request)
        }
    }
}
