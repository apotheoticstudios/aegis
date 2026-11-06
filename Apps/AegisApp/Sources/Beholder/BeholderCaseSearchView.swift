import SwiftUI

struct BeholderLocalResultsView: View {
    let report: BeholderCaseSearch.Report?
    let ip: BeholderIPContext.Info?
    let kind: BeholderCaseSearch.Kind
    var onOpenPerson: ((UUID) -> Void)?
    let onReview: (BeholderPeopleView.Target) -> Void
    @State private var showAllPeople = false
    @State private var provider: BeholderProvider?
    @State private var status: BeholderFinding.Status?
    @State private var pageIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.space3) {
            if let ip {
                Text("IP ADDRESS CONTEXT").hudType(.data)
                Text(verbatim: ip.canonical).hudType(.readout).textSelection(.enabled)
                Text(ip.version + " · " + ip.category.replacingOccurrences(of: "-", with: " ").capitalized).foregroundStyle(HUD.primary)
                Text(ip.explanation)
            } else if let report {
                Text("SAVED \(report.kind.rawValue.uppercased()) MATCHES · " + report.query).hudType(.data).textSelection(.enabled)
                Text("\(report.people.count) saved people · \(report.total) saved accounts")
                    .hudType(.caption).foregroundStyle(HUD.inkMuted)
                if report.hits.isEmpty, report.people.isEmpty {
                    Text("No saved matches for this interpretation.")
                        .hudType(.caption).foregroundStyle(HUD.inkMuted)
                }
                ForEach(report.people.prefix(showAllPeople ? report.people.count : 4)) { hit in
                    VStack(alignment: .leading, spacing: HUD.space2) {
                        HStack {
                            Text(verbatim: hit.person.name).hudType(.bodyStrong)
                            Spacer()
                            if let onOpenPerson {
                                Button("Open investigation") { onOpenPerson(hit.id) }
                            }
                        }
                        reasonDetails(hit.reason, showValue: hit.reason.value != hit.person.name)
                    }.padding(HUD.space3).frame(maxWidth: .infinity, alignment: .leading).background(HUD.surface)
                }
                if report.people.count > 4 {
                    Button(showAllPeople ? "Show fewer people" : "Show more people") { showAllPeople.toggle() }
                        .buttonStyle(HUDChipStyle())
                }
                if report.total > 0 || provider != nil || status != nil {
                    accountResults(report)
                }
            } else {
                Text(
                    kind == .ip ? "Inspect a numeric IP address locally. No network, location or identity lookup runs automatically."
                        :
                        "Search saved profile names, recorded public identifiers and supported person links. No private Contacts or message data is searched."
                )
                .foregroundStyle(HUD.inkMuted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .beholderStyle()
            .onChange(of: report?.query) { resetResults() }
            .onChange(of: kind) { resetResults() }
    }

    private func resetResults() {
        showAllPeople = false
        provider = nil
        status = nil
        pageIndex = 0
    }

    private func accountResults(_ report: BeholderCaseSearch.Report) -> some View {
        let page = report.accountPage(provider: provider, status: status, index: pageIndex)
        let sources = report.providers
        return VStack(alignment: .leading, spacing: HUD.space3) {
            HStack {
                Picker("Saved source", selection: Binding(get: { provider }, set: { provider = $0; pageIndex = 0 })) {
                    Text("All sources").tag(BeholderProvider?.none)
                    ForEach(sources) { Text($0.title).tag(Optional($0)) }
                    // A case edit may remove the last match from the selected source.
                    if let provider, !sources.contains(provider) {
                        Text(provider.title).tag(Optional(provider))
                    }
                }
                Picker("Evidence status", selection: Binding(get: { status }, set: { status = $0; pageIndex = 0 })) {
                    Text("All evidence").tag(BeholderFinding.Status?.none)
                    Text("Public candidates").tag(Optional(BeholderFinding.Status.candidate))
                    Text("Manual links").tag(Optional(BeholderFinding.Status.manual))
                    Text("Historical matches").tag(Optional(BeholderFinding.Status.noResult))
                }
                Spacer(minLength: 0)
            }.fixedSize(horizontal: false, vertical: true)
            if page.hits.isEmpty {
                HStack {
                    Text("No accounts match these filters.").hudType(.caption).foregroundStyle(HUD.inkMuted)
                    Button("Clear filters") { provider = nil; status = nil; pageIndex = 0 }
                }
            } else {
                HStack {
                    Text("Showing \(page.hits.startIndex + 1)–\(page.hits.endIndex) of \(page.total) accounts")
                        .hudType(.caption).foregroundStyle(HUD.inkMuted)
                    Spacer()
                    if page.index > 0 || page.hasNext {
                        Button("Previous") { pageIndex = page.index - 1 }.disabled(page.index == 0)
                        Button("Next") { pageIndex = page.index + 1 }.disabled(!page.hasNext)
                    }
                }
                ForEach(page.hits) { accountCard($0) }
            }
        }.onChange(of: page.total) {
            pageIndex = report.accountPage(provider: provider, status: status, index: pageIndex).index
        }
    }

    private func accountCard(_ hit: BeholderCaseSearch.Hit) -> some View {
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
            if let first = hit.reasons.first {
                reasonDetails(first)
            }
            if hit.reasons.count > 1 {
                DisclosureGroup("More matching evidence · \(hit.reasons.count - 1)") {
                    ForEach(hit.reasons.dropFirst()) { reason in reasonDetails(reason) }
                }
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

    private func reasonDetails(_ reason: BeholderCaseSearch.Reason, showValue: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(reason.label).foregroundStyle(HUD.primary)
            if showValue {
                Text(verbatim: reason.value).textSelection(.enabled)
            }
            if let source = reason.source {
                Text(verbatim: source.absoluteString).textSelection(.enabled)
            }
            if let date = reason.date {
                Text("Recorded " + date.formatted())
            }
        }.hudType(.caption)
    }
}
