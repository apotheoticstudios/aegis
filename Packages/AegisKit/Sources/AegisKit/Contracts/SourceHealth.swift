import Foundation

/// Pure, content-free source health for the panel (#186). Fixes are suggestions, never executed here.
public enum SourceHealth {
    /// Fixed presentation states; empty successful scans remain healthy.
    public enum State: String, Codable, Sendable, CaseIterable {
        case healthy, notInstalled, permissionMissing, formatChanged, transientFailure, stale
    }

    /// A panel may offer these fixed owner actions. Collected data cannot choose an arbitrary action.
    public enum FixAction: String, Codable, Sendable {
        case openPrivacySettings, startMail, none
    }

    /// One source's state and suggested fix, containing no collected text.
    public struct Line: Codable, Sendable, Hashable {
        public let source: SourceKind
        public let state: State
        public let fix: FixAction

        public init(source: SourceKind, state: State, fix: FixAction) {
            self.source = source
            self.state = state
            self.fix = fix
        }
    }

    /// The maximum age of a successful scan before a source can be stale.
    public static let staleAfter: TimeInterval = 30 * 60

    /// Sorted lines, with staleness inferred only when a different source has succeeded recently.
    /// For a source that has never succeeded, the engine supplies `.stale` after its observation window.
    public static func lines(_ coverage: [SourceCoverage], now: Date) -> [Line] {
        coverage.sorted { $0.source.rawValue < $1.source.rawValue }.map { item in
            let code = isStale(item, among: coverage, since: item.lastSuccess, now: now) ? .stale : item.status
            let state = state(for: code)
            let fix: FixAction = if state == .permissionMissing {
                .openPrivacySettings
            } else if item.source == .mail, state == .notInstalled || state == .stale {
                .startMail
            } else {
                .none
            }
            return Line(source: item.source, state: state, fix: fix)
        }
    }

    static func isStale(_ item: SourceCoverage, among coverage: [SourceCoverage], since: Date?, now: Date) -> Bool {
        guard let baseline = item.lastSuccess ?? since, now.timeIntervalSince(baseline) >= staleAfter else {
            return false
        }
        return coverage.contains { peer in
            guard peer.source != item.source, let success = peer.lastSuccess else { return false }
            return success > baseline && success <= now && now.timeIntervalSince(success) < staleAfter
        }
    }

    private static func state(for code: SourceStatus.Code) -> State {
        switch code {
        case .ok, .noData: .healthy
        case .notFound: .notInstalled
        case .permissionDenied: .permissionMissing
        case .formatChanged: .formatChanged
        case .busy, .unreadable: .transientFailure
        case .stale: .stale
        }
    }
}
