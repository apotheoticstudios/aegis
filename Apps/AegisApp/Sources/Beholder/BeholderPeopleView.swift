import SwiftUI

/// Local case editor. Returned profile text cannot create people, link accounts or start another search.
struct BeholderPeopleView: View {
    struct Target: Identifiable {
        let id = UUID()
        let username: String
        let finding: BeholderFinding
        var originalPersonID: UUID?
        var originalLinkID: UUID?
        var preferredPersonID: UUID?

        func permits(_ personID: UUID?) -> Bool {
            guard let personID else { return false }
            return (originalPersonID ?? preferredPersonID).map { $0 == personID } ?? true
        }
    }

    let research: BeholderModel
    /// Shown in the dashboard's People tab rather than a sheet: no Done button, full width.
    var embedded = false
    @State private var selected: UUID?
    @State private var name = ""
    @State private var draft: Target?
    @State private var assessment = BeholderPeople.Assessment.possible
    @State private var reason = ""
    @State private var evidence = ""
    @State private var problem: String?
    @State private var expandedGroups: Set<BeholderPeople.Assessment> = [.supported, .possible]
    @Environment(\.dismiss) private var dismiss

    init(research: BeholderModel, personID: UUID? = nil, target: Target? = nil, embedded: Bool = false) {
        self.research = research
        self.embedded = embedded
        let preferred = (target?.preferredPersonID ?? personID).flatMap { id in research.people.people.first { $0.id == id }?.id }
        _selected = State(initialValue: preferred ?? (research.people.people.count == 1 ? research.people.people.first?.id : nil))
        _draft = State(initialValue: target)
    }

    var body: some View {
        if embedded {
            ScrollViewReader { proxy in
                ScrollView { content }
                    .onChange(of: draft?.id) { _, id in
                        if id != nil {
                            proxy.scrollTo("account-review", anchor: .top)
                        }
                    }
            }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: HUD.space3) {
            if !embedded {
                HStack {
                    Text("PEOPLE IN THIS CASE").hudType(.data)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            Text("Group accounts using evidence you have reviewed. A matching handle alone does not establish who owns it.")
                .foregroundStyle(HUD.inkMuted)
            if research.includesImportedObservations {
                Text(
                    "This case includes imported claims. Stored source checks and owner assessments have not been independently rechecked."
                )
                .hudType(.caption).foregroundStyle(HUD.warn)
            }
            HStack {
                TextField("Person label", text: $name).modifier(BeholderField())
                    .accessibilityLabel("New person label")
                Button("Create person") {
                    perform { selected = try research.people.create(name); name = "" }
                }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Picker("Person", selection: $selected) {
                Text("Select a person").tag(UUID?.none)
                ForEach(research.people.people) { Text(verbatim: $0.name).tag(Optional($0.id)) }
            }
            if let draft {
                editor(draft).id("account-review")
            }
            if let problem {
                Text(problem).foregroundStyle(HUD.warn)
            }
            if let person = research.people.people.first(where: { $0.id == selected }) {
                if embedded {
                    BeholderInvestigationView(research: research, person: person) { target in
                        draft = target; assessment = .possible; reason = ""; evidence = ""; problem = nil
                    }.id(person.id)
                }
                Text("\(person.links.count) ACCOUNTS · " + person.name).hudType(.data)
                Group {
                    if embedded {
                        accountLinks(person)
                    } else {
                        ScrollView { accountLinks(person) }.frame(maxHeight: 300)
                    }
                }
                if person.links.isEmpty {
                    Text("Search a known username in Results, choose this person, then Save as possible.").foregroundStyle(HUD.inkMuted)
                }
            }
            Text("Kept in memory only. Export the case before closing Aegis. Evidence URLs are stored, never fetched.")
                .hudType(.caption).foregroundStyle(HUD.inkMuted)
        }
        .padding(embedded ? 0 : HUD.space4).frame(width: embedded ? nil : 680, alignment: .leading)
        .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
        .foregroundStyle(HUD.ink).background(embedded ? AnyShapeStyle(.clear) : AnyShapeStyle(HUD.void)).beholderStyle()
        .onChange(of: selected) {
            if let draft, !draft.permits(selected) {
                self.draft = nil
            }
            expandedGroups = [.supported, .possible]
            assessment = .possible; reason = ""; evidence = ""; problem = nil
        }
    }

    private func accountLinks(_ person: BeholderPeople.Person) -> some View {
        LazyVStack(alignment: .leading, spacing: HUD.space3) {
            ForEach([BeholderPeople.Assessment.supported, .possible, .ruledOut]) { group in
                let links = person.links.filter { $0.assessment == group }.sorted { $0.accountKey < $1.accountKey }
                if !links.isEmpty {
                    DisclosureGroup(group.title + " · \(links.count)", isExpanded: Binding(
                        get: { expandedGroups.contains(group) },
                        set: {
                            if $0 {
                                expandedGroups.insert(group)
                            } else {
                                expandedGroups.remove(group)
                            }
                        }
                    )) {
                        ForEach(links) { link in
                            VStack(alignment: .leading, spacing: HUD.space2) {
                                HStack {
                                    Text(link.finding.provider.title + " · @" + link.username).hudType(.label)
                                    Spacer()
                                    Text(link.assessment.title).hudType(.caption).foregroundStyle(HUD.primary)
                                }
                                Text(verbatim: link.reason).textSelection(.enabled)
                                if let url = link.evidenceURL {
                                    Text("Your evidence: " + url.absoluteString).textSelection(.enabled)
                                }
                                Text("Your assessment: " + link.assessedAt.formatted(date: .abbreviated, time: .standard))
                                if let checked = link.finding.checkedAt {
                                    Text("Original source check: " + checked.formatted(date: .abbreviated, time: .standard))
                                    if let latest = link.lastObservedAt, latest > checked {
                                        Text("Seen again: " + latest
                                            .formatted(date: .abbreviated, time: .standard) + " · original snapshot retained")
                                    }
                                } else {
                                    Text("Manual profile · Beholder has not checked this account")
                                }
                                if let current = research.correlation.accounts.first(where: { $0.id == link.accountKey }) {
                                    if current.finding.status == .noResult {
                                        Text("Historical account: latest completed check had no public result.").foregroundStyle(HUD.warn)
                                    } else if current.pending {
                                        Text("Re-check pending; original snapshot retained.").foregroundStyle(HUD.inkMuted)
                                    }
                                }
                                DisclosureGroup("Saved profile details") {
                                    ForEach(link.finding.fields.keys.sorted(), id: \.self) { key in
                                        Text(key + ": " + (link.finding.fields[key] ?? "")).textSelection(.enabled)
                                    }
                                }
                                if let source = link.finding.sourceURL ?? link.finding.preparedProfileURL {
                                    Text(verbatim: source.absoluteString).textSelection(.enabled)
                                }
                                HStack {
                                    if let url = link.finding.provider.profileURL(link.username) {
                                        Link("Open profile ↗", destination: url)
                                            .help(
                                                "Opens your browser using its current settings. The saved snapshot may be older than the current page."
                                            )
                                    }
                                    Button("Review link") {
                                        draft = Target(
                                            username: link.username,
                                            finding: link.finding,
                                            originalPersonID: person.id,
                                            originalLinkID: link.id
                                        )
                                        assessment = link.assessment; reason = link.reason
                                        evidence = link.evidenceURL?.absoluteString ?? ""; problem = nil
                                    }
                                    Button("Remove link") { research.people.remove(personID: person.id, linkID: link.id) }
                                }
                            }
                            .hudType(.caption).padding(HUD.space3).background(HUD.surface)
                        }
                    }
                }
            }
        }
    }

    private func editor(_ target: Target) -> some View {
        VStack(alignment: .leading, spacing: HUD.space2) {
            Text("LINK " + target.finding.provider.title + " · @" + target.username).hudType(.data)
            Text("To: " + (research.people.people.first(where: { $0.id == selected })?.name ?? "Select a person"))
                .hudType(.label)
            HUDSegmented(
                label: "Assessment",
                options: BeholderPeople.Assessment.allCases.map { HUDOption(value: $0, label: $0.title) },
                value: $assessment,
                small: true
            )
            TextField("Why do you link or rule out this account?", text: $reason)
                .modifier(BeholderField())
                .accessibilityLabel("Account link explanation")
            TextField("Public evidence URL (required for support)", text: $evidence).modifier(BeholderField())
                .accessibilityLabel("Account link evidence URL")
            HStack {
                Button("Save assessment") {
                    perform {
                        guard let selected, target.permits(selected) else { throw BeholderPeople.Problem.missing }
                        if let original = target.originalPersonID, let linkID = target.originalLinkID {
                            guard original == selected else { throw BeholderPeople.Problem.missing }
                            try research.people.reassess(
                                personID: original,
                                linkID: linkID,
                                assessment: assessment,
                                reason: reason,
                                evidence: evidence
                            )
                        } else {
                            try research.people.link(
                                personID: selected,
                                username: target.username,
                                finding: target.finding,
                                assessment: assessment,
                                reason: reason,
                                evidence: evidence
                            )
                        }
                        draft = nil; reason = ""; evidence = ""; assessment = .possible
                    }
                }.disabled(selected == nil)
                Button("Cancel edit") { draft = nil; problem = nil }
            }
        }.padding(HUD.space3).overlay(Rectangle().stroke(HUD.line, lineWidth: 1))
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); problem = nil }
        catch let error as BeholderPeople.Problem { problem = error.message }
        catch { problem = "The case could not be updated." }
    }
}
