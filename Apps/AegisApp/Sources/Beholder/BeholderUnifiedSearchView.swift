import SwiftUI

struct BeholderUnifiedSearchView: View {
    private enum Section { case saved, alternate, publicLookups }

    let research: BeholderModel
    let onOpenPerson: (UUID) -> Void
    let onReview: (BeholderPeopleView.Target) -> Void

    private var search: BeholderUnifiedSearch {
        research.unifiedSearch
    }

    var body: some View {
        @Bindable var search = search
        VStack(alignment: .leading, spacing: HUD.space3) {
            HStack(alignment: .top, spacing: HUD.space3) {
                HUDTermInput(
                    prompt: "find >", text: $search.query,
                    placeholder: "Name, @username, email, phone or IP address", hint: "⏎ search"
                )
                .onSubmit { search.run(in: research) }
                .accessibilityLabel("Unified research search")
                Button("Search") { search.run(in: research) }
                    .buttonStyle(HUDPlateStyle(kind: .primary)).disabled(!search.canPrepare)
                if research.searching || research.githubDiscovery.searching {
                    Button("Stop") { research.stopLookup(); research.githubDiscovery.stop() }
                        .buttonStyle(HUDPlateStyle(kind: .critical))
                }
            }
            HStack(spacing: HUD.space3) {
                Menu {
                    Button("Recognise automatically") { search.interpret(as: nil) }
                    ForEach(BeholderCaseSearch.Kind.allCases) { kind in
                        Button("Treat as " + kind.rawValue.lowercased()) { search.interpret(as: kind) }
                    }
                } label: {
                    Text((search.automatic ? "Detected as " : "Treating as ") + (search.kind?.rawValue ?? "…"))
                        .hudType(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .hudType(.caption)
                .accessibilityLabel("Change search interpretation")
                if search.ambiguous {
                    Text("Search checks both names and usernames in your case.")
                        .hudType(.caption).foregroundStyle(HUD.inkMuted)
                }
                if search.kind == .phone {
                    Picker("Phone format", selection: $search.region) {
                        Text("International +").tag(BeholderQueryPlanner.PhoneRegion.international)
                        Text("Australia").tag(BeholderQueryPlanner.PhoneRegion.australia)
                    }.fixedSize()
                }
                Spacer(minLength: 0)
            }
            Text(search.requestSummary).hudType(.caption).foregroundStyle(HUD.inkMuted)
            if search.canPrepare, search.kind != .phone, search.kind != .ip {
                DisclosureGroup("Search destinations") {
                    ScrollView { VStack(alignment: .leading, spacing: HUD.space2) { destinations } }.frame(height: 120)
                }
            }
            if let problem = search.problem ?? search.inputHint {
                Text(problem).hudType(.caption).foregroundStyle(HUD.warn)
            }
            if let input = search.prepared {
                preparedResults(input)
            } else {
                VStack(alignment: .leading, spacing: HUD.space3) {
                    Text("Start with what you know.").hudType(.bodyStrong)
                    Text("Enter an identifier above. Search checks saved evidence and retrieves matching public profiles.")
                        .hudType(.caption).foregroundStyle(HUD.inkMuted)
                    Text("Results appear here with their sources and matching evidence.").hudType(.caption)
                        .foregroundStyle(HUD.inkMuted)
                }
            }
        }
        .beholderStyle()
    }

    private func preparedResults(_ input: BeholderPublicSearch.Input) -> some View {
        let saved = search.report(in: research)
        let alternate = search.report(in: research, alternate: true)
        return ScrollViewReader { proxy in
            if input.kind != .ip {
                HStack {
                    Button("Search results") { proxy.scrollTo(Section.publicLookups, anchor: .top) }
                    Button((alternate == nil ? "Saved matches · " : "As username · ") + count(saved)) {
                        proxy.scrollTo(Section.saved, anchor: .top)
                    }
                    if let alternate {
                        Button("As name · " + count(alternate)) { proxy.scrollTo(Section.alternate, anchor: .top) }
                    }
                }.buttonStyle(HUDChipStyle()).frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: HUD.space4) {
                    if input.kind != .ip {
                        publicLookups(input).id(Section.publicLookups)
                    }
                    BeholderLocalResultsView(
                        report: saved, ip: search.ip, kind: input.kind, onOpenPerson: onOpenPerson, onReview: onReview
                    ).id(Section.saved)
                    if let alternate {
                        VStack(alignment: .leading, spacing: HUD.space3) {
                            HStack {
                                Text("Search also checked the name locally.").hudType(.caption).foregroundStyle(HUD.inkMuted)
                                Spacer()
                                Button("Treat as name") { search.interpret(as: .name); search.prepare() }
                                    .buttonStyle(HUDChipStyle())
                            }
                            BeholderLocalResultsView(
                                report: alternate, ip: nil, kind: .name, onOpenPerson: onOpenPerson, onReview: onReview
                            )
                        }.id(Section.alternate)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, HUD.space2)
            }
            .onChange(of: input) { proxy.scrollTo(input.kind == .ip ? Section.saved : .publicLookups, anchor: .top) }
        }
    }

    private func count(_ report: BeholderCaseSearch.Report?) -> String {
        let people = report?.people.count ?? 0
        let accounts = report?.total ?? 0
        return "\(people) \(people == 1 ? "person" : "people") · \(accounts) \(accounts == 1 ? "account" : "accounts")"
    }

    @ViewBuilder private var destinations: some View {
        if search.kind == .username, let name = BeholderCaseSearch.username(search.query) {
            ForEach(BeholderProvider.automaticSources) { provider in
                if let url = provider.endpoint(name) {
                    Text(provider.title + " · " + url.absoluteString).hudType(.caption).textSelection(.enabled)
                }
            }
            Text("The supported sources receive this username, your IP address and app request metadata.")
                .hudType(.caption).foregroundStyle(HUD.inkMuted)
        } else if search.kind == .name || search.kind == .email,
                  let request = BeholderGitHubDiscovery.prepare(.init(
                      value: search.query, kind: search.kind == .name ? .name : .email
                  ))
        {
            Text(verbatim: request.endpoint.absoluteString).hudType(.caption).textSelection(.enabled)
            Text("GitHub receives this query and requests for up to 20 returned profiles, with your IP address and app request metadata.")
                .hudType(.caption).foregroundStyle(HUD.inkMuted)
        }
    }

    private func publicLookups(_ input: BeholderPublicSearch.Input) -> some View {
        VStack(alignment: .leading, spacing: HUD.space3) {
            if input.kind == .username {
                Text("AUTOMATIC PROFILE RESULTS").hudType(.data)
                if search.profileQuery == research.username, search.profileQuery != nil {
                    if let problem = research.problem {
                        Text(problem).hudType(.caption).foregroundStyle(HUD.warn)
                    }
                    BeholderResultsView(
                        findings: research.findings, username: research.username, searching: research.searching,
                        research: research, embedded: true
                    ) { finding in onReview(.init(username: research.username, finding: finding)) }
                } else {
                    Text("Press Search to retrieve public profiles.").hudType(.caption).foregroundStyle(HUD.inkMuted)
                }
            } else if input.kind == .name || input.kind == .email {
                Text("GITHUB PROFILE RESULTS").hudType(.data)
                BeholderGitHubDiscoveryView(
                    discovery: research.githubDiscovery, research: research, embedded: true, onReview: onReview
                )
            } else {
                Text("Phone searches currently use saved case evidence.").hudType(.caption).foregroundStyle(HUD.inkMuted)
            }
        }
    }
}
