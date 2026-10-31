@testable import Aegis
import AppKit
import SwiftUI
import XCTest

/// Invented findings only: nothing here sends a request or describes a real person.
final class BeholderEvidenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func finding(
        _ provider: BeholderProvider, _ status: BeholderFinding.Status, checked: Bool = true, handle: String? = "ExampleAlex"
    ) -> BeholderFinding {
        BeholderFinding(
            provider: provider,
            status: status,
            checkedAt: checked ? now : nil,
            sourceURL: provider.endpoint("ExampleAlex"),
            fields: handle.map { ["Handle": $0] } ?? [:]
        )
    }

    func testOnlyRecordedChecksCountAsObservations() {
        let run = [
            finding(.github, .candidate),
            finding(.gitlab, .noResult),
            finding(.hackerNews, .limited),
            finding(.dev, .unavailable),
            finding(.codeberg, .queued, checked: false),
            finding(.dockerHub, .checking, checked: false),
            finding(.keybase, .cancelled, checked: false),
            finding(.lichess, .cancelled), // the client stamps a stop time; that is not an answer
            finding(.chess, .candidate, checked: false),
        ]
        for item in run where item.checkedAt == nil {
            XCTAssertNotNil(item.sourceURL, "Fixture must carry an address to prove it is not enough")
            XCTAssertEqual(BeholderEvidence.outcome(item), .notChecked)
        }
        XCTAssertEqual(BeholderEvidence.outcome(run[7]), .notChecked)
        let summary = BeholderEvidence.summary(run)
        XCTAssertEqual(summary, .init(candidates: 1, noResult: 1, unresolved: 2, notChecked: 5, cancelled: 2, manual: 0))
        XCTAssertEqual(summary.completed, 4)
        XCTAssertTrue(summary.isPartial)
        XCTAssertEqual(
            summary.headline,
            "4 of 9 automatic checks completed · 1 candidate account · 1 no public result · 2 unresolved · 5 not checked (2 cancelled)"
        )
        XCTAssertEqual(
            summary.partialNote,
            "Partial run: 7 automatic sources gave no definite answer. Those results are unknown, not absent."
        )
        let cancelled = BeholderEvidence.explain(run[6])
        XCTAssertNil(cancelled.checkedAt)
        XCTAssertEqual(cancelled.provenance, ["Request not completed: " + (run[6].sourceURL?.absoluteString ?? "")])
        XCTAssertNil(BeholderEvidence.explain(run[7]).checkedAt)
    }

    func testCompleteRunIsNotPartialAndKeepsProvenance() throws {
        let run = [finding(.github, .candidate), finding(.gitlab, .noResult)]
        let summary = BeholderEvidence.summary(run)
        XCTAssertFalse(summary.isPartial)
        XCTAssertNil(summary.partialNote)
        XCTAssertEqual(summary.headline, "2 of 2 automatic checks completed · 1 candidate account · 1 no public result")
        let explained = BeholderEvidence.explain(run[0])
        XCTAssertEqual(explained.checkedAt, now)
        try XCTAssertEqual(explained.provenance, [
            "Checked " + now.formatted(.iso8601),
            "Requested: " + XCTUnwrap(run[0].sourceURL).absoluteString,
        ])
    }

    func testManualLinksNeverBecomeVerified() throws {
        let manual = try XCTUnwrap(BeholderProvider.instagram.manualFinding("ExampleAlex"))
        XCTAssertEqual(BeholderEvidence.outcome(manual), .manual)
        var tampered = manual
        tampered.status = .candidate
        tampered.checkedAt = now
        tampered.sourceURL = tampered.preparedProfileURL
        XCTAssertEqual(BeholderEvidence.outcome(tampered), .manual)
        let explained = BeholderEvidence.explain(tampered)
        XCTAssertNil(explained.checkedAt)
        XCTAssertNil(explained.requestURL)
        try XCTAssertEqual(
            explained.provenance,
            ["Prepared link, not opened or checked: " + XCTUnwrap(manual.preparedProfileURL).absoluteString]
        )
        XCTAssertTrue(explained.reason.contains("did not contact"))
        let unsupported = try XCTUnwrap(BeholderProvider.twitter.manualFinding("Example-Alex"))
        XCTAssertEqual(BeholderEvidence.outcome(unsupported), .manual)
        XCTAssertTrue(BeholderEvidence.explain(unsupported).reason.contains("no link was prepared"))
        let summary = BeholderEvidence.summary([manual, unsupported, finding(.github, .candidate)])
        XCTAssertEqual(summary.manual, 2)
        XCTAssertEqual(summary.candidates, 1)
        XCTAssertEqual(summary.headline, "1 of 1 automatic check completed · 1 candidate account · 2 unchecked links")
        XCTAssertEqual(BeholderEvidence.summary([manual]).headline, "No automatic checks · 1 unchecked link")
    }

    func testSameHandleAtDifferentSourcesStaysSeparate() {
        let github = finding(.github, .candidate)
        let gitlab = finding(.gitlab, .candidate)
        let stale = finding(.github, .queued, checked: false)
        let explained = BeholderEvidence.explanations([stale, gitlab, github, gitlab])
        XCTAssertEqual(explained.map(\.provider), [.github, .gitlab], "One entry per source, first-seen order, latest value")
        XCTAssertEqual(explained.map(\.outcome), [.candidate, .candidate])
        XCTAssertEqual(BeholderEvidence.summary([github, gitlab, gitlab]).candidates, 2)
        XCTAssertTrue(explained.allSatisfy { $0.reason.contains("does not show who runs it") })
    }

    func testExplanationsAreDeterministicAndNeverScoreIdentity() {
        let statuses: [BeholderFinding.Status] = [
            .queued,
            .checking,
            .candidate,
            .noResult,
            .unsupported,
            .limited,
            .unavailable,
            .cancelled,
        ]
        for status in statuses {
            for checked in [true, false] {
                for handle in ["ExampleAlex", nil] {
                    let item = finding(.github, status, checked: checked, handle: handle)
                    let first = BeholderEvidence.explain(item)
                    XCTAssertEqual(first, BeholderEvidence.explain(item))
                    XCTAssertFalse(first.reason.isEmpty)
                    XCTAssertFalse(first.reason.contains("%"), "No numeric identity probabilities")
                    XCTAssertFalse(first.reason.lowercased().contains("same person"))
                }
            }
        }
        XCTAssertTrue(BeholderEvidence.identityNote.contains("do not show"))
        XCTAssertTrue(BeholderEvidence.explain(finding(.github, .candidate, handle: nil)).reason.contains("a matching handle"))
    }

    @MainActor func testSyntheticEvidenceRendersAtCompactWidth() throws {
        guard ProcessInfo.processInfo.environment["RENDER_BEHOLDER"] == "1" else {
            throw XCTSkip("Opt-in native window capture: RENDER_BEHOLDER=1 on an unlocked Mac.")
        }
        let run = try [
            finding(.github, .candidate), finding(.gitlab, .noResult), finding(.hackerNews, .limited),
            finding(.codeberg, .cancelled, checked: false), XCTUnwrap(BeholderProvider.instagram.manualFinding("ExampleAlex")),
        ]
        let view = VStack(alignment: .leading, spacing: HUD.space4) {
            BeholderEvidenceSummaryView(findings: run)
            ForEach(run) { BeholderEvidenceExplanationView(finding: $0) }
        }
        .padding(HUD.space4).frame(width: 320, height: 760, alignment: .top).foregroundStyle(HUD.ink)
        .background(HUD.void).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 320, height: 760),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("beholder-evidence.png"))
    }
}
