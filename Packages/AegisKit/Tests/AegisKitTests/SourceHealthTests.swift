@testable import AegisKit
import Foundation
import XCTest

final class SourceHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_320_400)

    func testEachCodeMapsToAFixedStateAndFix() throws {
        let cases: [(SourceStatus.Code, (SourceHealth.State, SourceHealth.FixAction))] = [
            (.ok, (.healthy, .none)), (.noData, (.healthy, .none)),
            (.notFound, (.notInstalled, .startMail)),
            (.permissionDenied, (.permissionMissing, .openPrivacySettings)),
            (.formatChanged, (.formatChanged, .none)),
            (.busy, (.transientFailure, .none)), (.unreadable, (.transientFailure, .none)),
            (.stale, (.stale, .startMail)),
        ]
        for (code, (state, fix)) in cases {
            let item = SourceCoverage(source: .mail, status: code, events: 0, lastSuccess: nil)
            XCTAssertEqual(SourceHealth.lines([item], now: now), [.init(source: .mail, state: state, fix: fix)])
            XCTAssertEqual(try IPCCoding.decode(SourceCoverage.self, from: IPCCoding.encode(item)), item)
        }
        let missing = SourceCoverage(source: .messages, status: .notFound, events: 0, lastSuccess: nil)
        XCTAssertEqual(SourceHealth.lines([missing], now: now).first?.fix, SourceHealth.FixAction.none)
    }

    func testStalenessRequiresThirtyMinutesAndARecentSuccessfulPeer() {
        let old = SourceCoverage(source: .mail, status: .ok, events: 0, lastSuccess: now.addingTimeInterval(-1800))
        let peer = SourceCoverage(source: .messages, status: .noData, events: 0, lastSuccess: now)
        XCTAssertEqual(SourceHealth.lines([peer, old], now: now).map(\.source), [.mail, .messages])
        XCTAssertEqual(SourceHealth.lines([old, peer], now: now).first?.state, .stale)
        XCTAssertEqual(SourceHealth.lines([old, peer], now: now.addingTimeInterval(-1)).first?.state, .healthy)
        XCTAssertEqual(SourceHealth.lines([old], now: now).first?.state, .healthy)
        XCTAssertEqual(SourceHealth.lines([old, peer], now: now.addingTimeInterval(1800)).first?.state, .healthy)
    }

    func testFutureSuccessAndEqualOldScansDoNotImplyStaleness() {
        let old = SourceCoverage(source: .mail, status: .unreadable, events: 0, lastSuccess: now.addingTimeInterval(-1800))
        var peer = SourceCoverage(source: .messages, status: .ok, events: 0, lastSuccess: now.addingTimeInterval(1))
        XCTAssertEqual(SourceHealth.lines([old, peer], now: now).first?.state, .transientFailure)
        peer.lastSuccess = old.lastSuccess
        XCTAssertEqual(SourceHealth.lines([old, peer], now: now).first?.state, .transientFailure)
    }
}
