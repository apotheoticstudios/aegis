import Observation
import SwiftUI

/// Search intent is isolated from the username lookup model. Mode changes discard the old input.
@MainActor @Observable
final class BeholderDiscovery {
    let research: BeholderModel
    var kind = BeholderCaseSearch.Kind.username {
        didSet {
            if oldValue != kind {
                query = ""; clearResult()
                ownerTypedInput = false
            }
        }
    }

    var query: String {
        didSet {
            ownerTypedInput = true
            if oldValue != query {
                clearResult()
            }
        }
    }

    var region = BeholderQueryPlanner.PhoneRegion.international {
        didSet { clearResult() }
    }

    private var cachedReport: BeholderCaseSearch.Report?
    private var searchedRevision: UInt64?
    var report: BeholderCaseSearch.Report? {
        searchedRevision == research.caseRevision ? cachedReport : nil
    }

    private(set) var ip: BeholderIPContext.Info?
    private var inputProblem: String?
    var problem: String? {
        inputProblem ?? (kind == .username ? BeholderCaseSearch.usernameProblem(query) : nil) ??
            (cachedReport != nil && report == nil ? "Case evidence changed. Run this search again to see current matches." : nil)
    }

    private(set) var ownerTypedInput = false

    init(_ research: BeholderModel) {
        self.research = research; query = research.query
    }

    var canSearch: Bool {
        kind == .username ? BeholderCaseSearch.username(query) != nil && !research.providers.isEmpty : !query.isEmpty
    }

    var actionTitle: String {
        kind == .username ? "Search public sources" : kind == .ip ? "Inspect IP address" : "Search this case"
    }

    func search() {
        clearResult()
        if kind == .username {
            guard BeholderCaseSearch.username(query) != nil else {
                inputProblem = BeholderCaseSearch.usernameProblem(query) ?? "Enter one valid username."
                return
            }
            research.query = query
            research.start()
            return
        }
        if kind == .ip {
            ip = BeholderIPContext.inspect(query)
            if ip == nil {
                inputProblem = "Enter one numeric IPv4 or IPv6 address, without a URL, port, prefix or zone."
            }
            return
        }
        do { cachedReport = try BeholderCaseSearch.compute(
            input: query,
            kind: kind,
            region: region,
            store: research.correlation,
            people: research.people
        )
        searchedRevision = research.caseRevision
        } catch { inputProblem = (error as? BeholderCaseSearch.Problem)?.message ?? "The case search could not be completed." }
    }

    func clearCase() {
        research.clear(); query = ""; clearResult(); ownerTypedInput = false
    }

    func resetAfterImport() {
        query = kind == .username ? research.username : ""; clearResult(); ownerTypedInput = false
    }

    private func clearResult() {
        cachedReport = nil; searchedRevision = nil; ip = nil; inputProblem = nil
    }
}

struct BeholderCaseSearchView: View {
    let discovery: BeholderDiscovery
    let onReview: (BeholderPeopleView.Target) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HUD.space3) {
                if let ip = discovery.ip {
                    Text("IP ADDRESS CONTEXT").hudType(.data)
                    Text(verbatim: ip.canonical).hudType(.readout).textSelection(.enabled)
                    Text(ip.version + " · " + ip.category.replacingOccurrences(of: "-", with: " ").capitalized).foregroundStyle(HUD.primary)
                    Text(ip.explanation)
                } else if let report = discovery.report {
                    Text("CASE MATCHES FOR " + report.query).hudType(.data).textSelection(.enabled)
                    Text("\(report.total) stored account match(es). Names and shared identifiers are leads, not verified identities.")
                        .hudType(.caption).foregroundStyle(HUD.inkMuted)
                    if report.hits.isEmpty {
                        Text(
                            "No matching evidence in this case. This does not mean no accounts exist; public searches can find additional pages to inspect."
                        )
                        .foregroundStyle(HUD.inkMuted)
                    }
                    ForEach(report.hits) { hit in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(hit.account.finding.provider.title + " · @" + hit.account.username).hudType(.label)
                                Spacer()
                                if [.candidate, .manual].contains(hit.account.finding.status) {
                                    Button("Review account link…") { onReview(.init(
                                        username: hit.account.username,
                                        finding: hit.account.finding
                                    )) }
                                }
                            }
                            if hit.historical {
                                Text("Historical evidence: the latest public check returned no matching record.").foregroundStyle(HUD.warn)
                            }
                            if let type = hit.account.finding.fields["Account type"] ?? hit.account.finding.fields["Profile type"] {
                                Text("Account type: " + type).hudType(.caption).foregroundStyle(HUD.inkMuted)
                            }
                            if hit.account.pending {
                                Text("Re-check pending; showing earlier dated evidence.").foregroundStyle(HUD.inkMuted)
                            } else if let attempt = hit.account.latestAttempt {
                                Text("Latest attempt: " + attempt.finding.status.title + "; earlier dated evidence retained.")
                                    .foregroundStyle(HUD.inkMuted)
                                if let date = attempt.finding.checkedAt {
                                    Text("Attempt recorded " + date.formatted()).hudType(.caption).foregroundStyle(HUD.inkMuted)
                                }
                            }
                            ForEach(hit.reasons) { reason in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(reason.label).foregroundStyle(HUD.primary)
                                    Text(verbatim: reason.value).textSelection(.enabled)
                                    if let source = reason.source {
                                        Text(verbatim: source.absoluteString).textSelection(.enabled)
                                    }
                                    if let date = reason.date {
                                        Text("Recorded " + date.formatted())
                                    }
                                }.hudType(.caption)
                            }
                            if hit.totalReasons > hit.reasons.count {
                                Text("Showing 20 of \(hit.totalReasons) saved references. Reference count is not identity confidence.")
                                    .hudType(.caption).foregroundStyle(HUD.inkMuted)
                            }
                            if let url = hit.account.finding.provider.profileURL(hit.account.username) {
                                Link("Open saved profile address ↗", destination: url).hudType(.caption)
                                    .help(
                                        "Opens your browser using its current settings. The address does not prove ownership or current availability."
                                    )
                            }
                        }.padding(HUD.space3).frame(maxWidth: .infinity, alignment: .leading).background(HUD.surface)
                    }
                    if report.total > report.hits
                        .count
                    {
                        Text("Showing the first 100 matches. Refine the input to narrow this case.").hudType(.caption)
                    }
                } else {
                    Text(
                        discovery.kind == .ip ? "Inspect a numeric IP address locally. No network, location or identity lookup runs automatically."
                            :
                            "Search saved profile names, recorded public identifiers and supported person links. No private Contacts or message data is searched."
                    )
                    .foregroundStyle(HUD.inkMuted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .beholderStyle()
    }
}
