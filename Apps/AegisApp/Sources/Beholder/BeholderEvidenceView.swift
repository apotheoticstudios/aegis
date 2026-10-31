import SwiftUI

/// Compact run summary: what was observed, the partial-run warning and the identity caveat.
struct BeholderEvidenceSummaryView: View {
    let findings: [BeholderFinding]

    var body: some View {
        let summary = BeholderEvidence.summary(findings)
        VStack(alignment: .leading, spacing: HUD.space2) {
            Text(summary.headline).hudType(.data).foregroundStyle(HUD.primary)
            if let note = summary.partialNote {
                Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(HUD.warn)
            }
            Text(BeholderEvidence.identityNote).font(.caption).foregroundStyle(HUD.inkMuted)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One finding's outcome, plain-language reason and provenance. Never a score.
struct BeholderEvidenceExplanationView: View {
    let explanation: BeholderEvidence.Explanation

    init(finding: BeholderFinding) {
        explanation = BeholderEvidence.explain(finding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.space1) {
            Text(explanation.outcome.title.uppercased()).font(.caption2).foregroundStyle(tint)
            Text(verbatim: explanation.reason).font(.caption)
            ForEach(explanation.provenance, id: \.self) { line in
                Text(verbatim: line).font(.caption2).foregroundStyle(HUD.inkMuted).textSelection(.enabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var tint: HUDColor {
        switch explanation.outcome {
        case .candidate: HUD.primary
        case .unresolved: HUD.warn
        case .noResult, .notChecked, .manual: HUD.inkMuted
        }
    }
}
