import SwiftUI

struct BeholderUnifiedSearchView: View {
    private enum Section { case saved, alternate, publicLookups }

    let research: BeholderModel
    let onSources: () -> Void
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
                .onSubmit { search.prepare() }
                .accessibilityLabel("Unified research search")
                Button("Search") { search.prepare() }
                    .buttonStyle(HUDPlateStyle(kind: .primary)).disabled(!search.canPrepare)
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
            if let problem = search.problem ?? search.inputHint {
                Text(problem).hudType(.caption).foregroundStyle(HUD.warn)
            }
            if let input = search.prepared {
                preparedResults(input)
            } else {
                VStack(alignment: .leading, spacing: HUD.space3) {
                    Text("Start with what you know.").hudType(.bodyStrong)
                    Text("Enter an identifier above. Search checks saved evidence and prepares the relevant public lookup options.")
                        .hudType(.caption).foregroundStyle(HUD.inkMuted)
                    Text("Public checks show their destinations before you run them.").hudType(.caption)
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
                    Button((alternate == nil ? "Saved matches · " : "As username · ") + count(saved)) {
                        proxy.scrollTo(Section.saved, anchor: .top)
                    }
                    if let alternate {
                        Button("As name · " + count(alternate)) { proxy.scrollTo(Section.alternate, anchor: .top) }
                    }
                    Button("Public lookups") { proxy.scrollTo(Section.publicLookups, anchor: .top) }
                }.buttonStyle(HUDChipStyle()).frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: HUD.space4) {
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
                    if input.kind != .ip {
                        publicLookups(input).id(Section.publicLookups)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, HUD.space2)
            }
            .onChange(of: input) { proxy.scrollTo(Section.saved, anchor: .top) }
        }
    }

    private func count(_ report: BeholderCaseSearch.Report?) -> String {
        "\((report?.total ?? 0) + (report?.people.count ?? 0))"
    }

    private func publicLookups(_ input: BeholderPublicSearch.Input) -> some View {
        VStack(alignment: .leading, spacing: HUD.space4) {
            if input.kind == .username {
                profiles(input)
            } else if input.kind == .name || input.kind == .email {
                Text("PUBLIC GITHUB DISCOVERY").hudType(.data)
                if research.githubDiscovery.prepared == nil {
                    Button("Prepare GitHub search") { search.chooseGitHub() }.buttonStyle(HUDChipStyle())
                    if let problem = research.githubDiscovery.problem {
                        Text(problem.message).hudType(.caption).foregroundStyle(HUD.warn)
                    }
                } else {
                    BeholderGitHubDiscoveryView(
                        discovery: research.githubDiscovery, research: research, embedded: true, onReview: onReview
                    )
                }
            }
            BeholderPublicSearchView(input: input, ownerTyped: true)
        }
    }

    private func profiles(_ input: BeholderPublicSearch.Input) -> some View {
        VStack(alignment: .leading, spacing: HUD.space3) {
            Text("PUBLIC PROFILE CHECKS").hudType(.data)
            Button("Sources · " + BeholderSources.summary(research.selected), action: onSources).buttonStyle(HUDChipStyle())
            Text(profileSummary(input))
                .hudType(.caption).foregroundStyle(HUD.inkMuted)
            DisclosureGroup("Preview selected destinations") {
                ForEach(research.providers) { provider in
                    if let name = BeholderCaseSearch.username(input.value), let url = provider.endpoint(name) {
                        Text(provider.title + " · " + url.absoluteString).hudType(.caption).textSelection(.enabled)
                    }
                }
                Text("Manual source links open in your browser only when you choose them.").hudType(.caption)
            }
            if research.searching {
                Button("Stop checks") { research.stopLookup() }.buttonStyle(HUDChipStyle(muted: true))
            } else {
                Button("Search selected profiles") { search.searchProfiles(in: research) }
                    .buttonStyle(HUDChipStyle()).disabled(research.providers.isEmpty)
            }
            if search.profileQuery == research.username, search.profileQuery != nil {
                if let problem = research.problem {
                    Text(problem).hudType(.caption).foregroundStyle(HUD.warn)
                }
                Text("Completed public checks are also retained in the saved evidence above.")
                    .hudType(.caption).foregroundStyle(HUD.inkMuted)
                BeholderResultsView(
                    findings: research.findings, username: research.username, searching: research.searching,
                    research: research, embedded: true
                ) { finding in onReview(.init(username: research.username, finding: finding)) }
            }
        }
    }

    private func profileSummary(_ input: BeholderPublicSearch.Input) -> String {
        guard let name = BeholderCaseSearch.username(input.value) else { return "" }
        let eligible = research.providers.filter { $0.supports(name) }
        let automatic = eligible.filter { !$0.isManual }
        let manualCount = eligible.filter(\.isManual).count
        var summary = "“\(name)” · \(automatic.count) automatic checks · \(manualCount) manual browser links."
        if !automatic.isEmpty {
            summary += " Automatic sources receive the handle, your IP address and app identifier."
        }
        if automatic.contains(.bluesky) {
            summary += " Bluesky uses “\(BeholderProvider.bluesky.lookupHandle(name))”."
        }
        return summary
    }
}
