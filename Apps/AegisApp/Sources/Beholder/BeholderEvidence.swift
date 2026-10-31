import Foundation

/// Explains what a run did and did not observe. Pure and local: no requests, storage, scores or merging of accounts.
enum BeholderEvidence {
    enum Outcome: String, CaseIterable, Sendable {
        case candidate, noResult, unresolved, notChecked, manual

        var title: String {
            switch self {
            case .candidate: "Candidate account"
            case .noResult: "No public result"
            case .unresolved: "Unresolved"
            case .notChecked: "Not checked"
            case .manual: "Unchecked link"
            }
        }
    }

    struct Explanation: Equatable, Sendable, Identifiable {
        let provider: BeholderProvider
        let outcome: Outcome
        let reason: String
        /// Present only for a completed observation.
        let checkedAt: Date?
        let requestURL: URL?
        let preparedURL: URL?

        var id: BeholderProvider {
            provider
        }

        /// Source and time lines, worded so an address never reads as a completed check.
        var provenance: [String] {
            var lines: [String] = []
            if let checkedAt {
                lines.append("Checked " + checkedAt.formatted(.iso8601))
            }
            if let requestURL {
                lines.append((checkedAt == nil ? "Request not completed: " : "Requested: ") + requestURL.absoluteString)
            }
            if let preparedURL {
                lines.append("Prepared link, not opened or checked: " + preparedURL.absoluteString)
            }
            return lines
        }
    }

    struct Summary: Equatable, Sendable {
        let candidates: Int
        let noResult: Int
        let unresolved: Int
        let notChecked: Int
        let cancelled: Int
        let manual: Int

        var completed: Int {
            candidates + noResult + unresolved
        }

        var automatic: Int {
            completed + notChecked
        }

        /// Some automatic source gave no definite answer, so the run cannot speak for it.
        var isPartial: Bool {
            notChecked + unresolved > 0
        }

        var headline: String {
            var parts = [automatic == 0 ? "No automatic checks"
                : "\(completed) of \(automatic) automatic \(automatic == 1 ? "check" : "checks") completed"]
            for (count, one, many) in [
                (candidates, "candidate account", "candidate accounts"),
                (noResult, "no public result", "no public results"),
                (unresolved, "unresolved", "unresolved"),
            ] where count > 0 {
                parts.append("\(count) " + (count == 1 ? one : many))
            }
            if notChecked > 0 {
                parts.append("\(notChecked) not checked" + (cancelled > 0 ? " (\(cancelled) cancelled)" : ""))
            }
            if manual > 0 {
                parts.append("\(manual) unchecked " + (manual == 1 ? "link" : "links"))
            }
            return parts.joined(separator: " · ")
        }

        var partialNote: String? {
            guard isPartial else { return nil }
            let missing = notChecked + unresolved
            return "Partial run: \(missing) automatic \(missing == 1 ? "source" : "sources") gave no definite answer. "
                + "Those results are unknown, not absent."
        }
    }

    static let identityNote = "Each result is one account at one source. Matching handles, names, bios or photos "
        + "do not show that accounts belong to the same person."

    /// Only a recorded check time makes an automatic finding an observation; a request address alone does not.
    static func outcome(_ finding: BeholderFinding) -> Outcome {
        if finding.access == .manual || finding.status == .manual {
            return .manual
        }
        guard finding.checkedAt != nil else { return .notChecked }
        switch finding.status {
        case .candidate: return .candidate
        case .noResult: return .noResult
        case .limited, .unavailable: return .unresolved
        case .queued, .checking, .cancelled, .unsupported, .manual: return .notChecked
        }
    }

    /// One entry per source, in first-seen order with its latest value. Different sources are never merged.
    static func unique(_ findings: [BeholderFinding]) -> [BeholderFinding] {
        var order: [BeholderProvider] = []
        var latest: [BeholderProvider: BeholderFinding] = [:]
        for finding in findings where latest.updateValue(finding, forKey: finding.provider) == nil {
            order.append(finding.provider)
        }
        return order.compactMap { latest[$0] }
    }

    static func summary(_ findings: [BeholderFinding]) -> Summary {
        let items = unique(findings).map { ($0, outcome($0)) }
        let count = { (wanted: Outcome) in items.filter { $0.1 == wanted }.count }
        return Summary(
            candidates: count(.candidate),
            noResult: count(.noResult),
            unresolved: count(.unresolved),
            notChecked: count(.notChecked),
            cancelled: items.filter { $0.1 == .notChecked && $0.0.status == .cancelled }.count,
            manual: count(.manual)
        )
    }

    static func explanations(_ findings: [BeholderFinding]) -> [Explanation] {
        unique(findings).map(explain)
    }

    static func explain(_ finding: BeholderFinding) -> Explanation {
        let outcome = outcome(finding)
        let source = finding.provider.title
        let reason = switch outcome {
        case .candidate:
            "\(source) returned " + (finding.fields["Handle"].map { "the handle “\($0)”" } ?? "a matching handle") + " exactly. "
                + "An account with this handle exists there; that does not show who runs it or link it to any other result."
        case .noResult:
            "\(source) answered that no public account has this handle. "
                + "Private, renamed or removed accounts can look the same, so this does not prove absence."
        case .unresolved:
            finding.status == .limited
                ? "\(source) limited the request rate, so it gave no answer. Nothing is known about this source."
                : "\(source) did not give a usable answer (error, block or unexpected response). Nothing is known about this source."
        case .notChecked:
            switch finding.status {
            case .queued: "Waiting for a free slot; no request has completed."
            case .checking: "Request in progress; no answer yet."
            case .cancelled: "Stopped before an answer was recorded. A request address is not a completed check."
            case .unsupported: "This handle does not fit \(source)'s username rules, so no request was made."
            default: "No check time was recorded, so this is not counted as an observation."
            }
        case .manual:
            finding.status == .unsupported
                ? "This handle does not fit \(source)'s profile address rules, so no link was prepared."
                : "Beholder did not contact \(source). This is a prepared link to open yourself; whether an account exists is unknown."
        }
        let completed = [.candidate, .noResult, .unresolved].contains(outcome)
        return Explanation(
            provider: finding.provider,
            outcome: outcome,
            reason: reason,
            checkedAt: completed ? finding.checkedAt : nil,
            requestURL: outcome == .manual ? nil : finding.sourceURL,
            preparedURL: outcome == .manual ? finding.preparedProfileURL : nil
        )
    }
}
