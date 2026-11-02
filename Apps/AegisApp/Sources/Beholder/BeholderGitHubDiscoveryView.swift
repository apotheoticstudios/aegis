import SwiftUI

/// A separate input surface: case values are destinations for inspected profiles, never request seeds.
struct BeholderGitHubDiscoveryView: View {
    let discovery: BeholderGitHubResearch
    let research: BeholderModel
    let onReview: (BeholderPeopleView.Target) -> Void
    @State private var personID: UUID?
    @State private var saveNote: String?

    var body: some View {
        @Bindable var discovery = discovery
        ScrollView {
            VStack(alignment: .leading, spacing: HUD.space3) {
                Text("Find public GitHub accounts").hudType(.bodyStrong)
                Text("Search a name or email, inspect a public profile, then review whether it belongs in your investigation.")
                    .hudType(.caption).foregroundStyle(HUD.inkMuted)
                HUDSegmented(label: "Discover by", options: BeholderGitHubDiscovery.Kind.allCases.map {
                    HUDOption(value: $0, label: $0.rawValue)
                }, value: $discovery.kind)
                TextField(discovery.kind == .name ? "Name, e.g. Example Alex" : "Email, e.g. example@example.com", text: $discovery.value)
                    .modifier(BeholderField()).accessibilityLabel("GitHub discovery " + discovery.kind.rawValue.lowercased())
                if let request = discovery.prepared {
                    Text("EXACT GITHUB REQUEST").hudType(.data)
                    Text(verbatim: request.query).hudType(.term).textSelection(.enabled)
                    Text(verbatim: request.endpoint.absoluteString).hudType(.caption).textSelection(.enabled)
                    Text(
                        "Search sends this value to api.github.com with your IP address and app request metadata. No cookies or account credentials are used."
                    )
                    .hudType(.caption).foregroundStyle(HUD.inkMuted)
                    HStack {
                        Button("Search GitHub") { discovery.search(); saveNote = nil }
                            .buttonStyle(HUDPlateStyle(kind: .primary)).disabled(discovery.searching || discovery.inspecting != nil)
                        if discovery.searching || discovery.inspecting != nil {
                            ProgressView().controlSize(.small)
                            Button("Stop") { discovery.stop() }.buttonStyle(HUDChipStyle(muted: true))
                        }
                    }
                } else {
                    Button("Prepare GitHub search") { discovery.chooseGitHub() }
                        .buttonStyle(HUDChipStyle()).disabled(!discovery.canPrepare)
                }
                if let problem = discovery.problem {
                    Text(problem.message).hudType(.caption).foregroundStyle(HUD.warn)
                }
                if let page = discovery.page {
                    Text("\(page.total) matches reported by GitHub · showing \(page.hits.count) on the first page").hudType(.label)
                    Text(
                        "These are uninspected public search hits. GitHub uses containment in public fields, not exact name/email or identity matching."
                    )
                    .hudType(.caption).foregroundStyle(HUD.inkMuted)
                    Text("Search checked " + page.checkedAt.formatted()).hudType(.caption).foregroundStyle(HUD.inkMuted)
                    if page.incomplete {
                        Text("GitHub marked these search results incomplete. Missing accounts cannot be ruled out.")
                            .hudType(.caption).foregroundStyle(HUD.warn)
                    }
                    if page.hits.isEmpty {
                        Text("No public search hits were returned on this page. This does not establish that no accounts exist.")
                            .hudType(.caption)
                    }
                    ForEach(page.hits) { hit in
                        HStack {
                            Text("@" + hit.login).hudType(.label).textSelection(.enabled)
                            Text("Public User · uninspected search hit").hudType(.caption).foregroundStyle(HUD.inkMuted)
                            Spacer()
                            Button(discovery.inspecting == hit.login ? "Inspecting…" : "Inspect GitHub profile") {
                                discovery.inspect(hit, into: research); saveNote = nil
                            }.buttonStyle(HUDChipStyle()).disabled(discovery.inspecting != nil || discovery.searching)
                        }.padding(HUD.space2).background(HUD.surface)
                    }
                    if let finding = discovery.inspected, let login = discovery.inspectedLogin {
                        profile(finding, login: login, request: page.request)
                    }
                }
                Text("For other websites, phone numbers or IP context, use Search tools. Only the GitHub flow above runs inside this view.")
                    .hudType(.caption).foregroundStyle(HUD.inkMuted)
            }.padding(.trailing, HUD.space2)
        }
        .onChange(of: discovery.inspectedLogin) { _, _ in
            if research.people.people.count == 1 {
                personID = research.people.people.first?.id
            }
        }
        .onChange(of: research.people.people.map(\.id)) { _, ids in
            if let personID, !ids.contains(personID) {
                self.personID = nil
            }
        }
        .beholderStyle()
    }

    private func profile(_ finding: BeholderFinding, login: String, request: BeholderGitHubDiscovery.Request) -> some View {
        VStack(alignment: .leading, spacing: HUD.space2) {
            Text("INSPECTED PROFILE · @" + login).hudType(.data)
            Text("Selected through public GitHub user search; the profile was fetched only after your Inspect action.").hudType(.caption)
            BeholderEvidenceExplanationView(finding: finding)
            ForEach(finding.fields.keys.sorted(), id: \.self) { key in
                Text(key + ": " + (finding.fields[key] ?? "")).hudType(.caption).textSelection(.enabled)
            }
            if finding.status == .candidate {
                Text(BeholderGitHubDiscovery.compareEmail(finding, request: request).rawValue).hudType(.caption)
                    .foregroundStyle(HUD.primary)
                Picker("Investigation", selection: $personID) {
                    Text("Choose a person").tag(nil as UUID?)
                    ForEach(research.people.people) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                }
                HStack {
                    Button("Save as possible") {
                        guard let personID else { return }
                        do {
                            let added = try research.savePossible(personID: personID, username: login, finding: finding)
                            saveNote = added ? "Saved as possible. Review the evidence in People." : "The existing assessment was kept."
                        } catch { saveNote = (error as? BeholderPeople.Problem)?.message ?? "The account could not be saved." }
                    }.disabled(personID == nil)
                    Button("Review account link…") {
                        onReview(.init(username: login, finding: finding, preferredPersonID: personID))
                    }
                    if let url = BeholderProvider.github.profileURL(login) {
                        Link("Open profile ↗", destination: url).help("Opens your browser using its current settings.")
                    }
                }
                if research.people.people
                    .isEmpty
                {
                    Text("Create a person in People to collect this account for review.").hudType(.caption)
                }
            }
            if let saveNote {
                Text(saveNote).hudType(.caption).foregroundStyle(HUD.primary)
            }
        }.padding(HUD.space3).background(HUD.surface)
    }
}
