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
    }

    let research: BeholderModel
    @State private var selected: UUID?
    @State private var name = ""
    @State private var draft: Target?
    @State private var assessment = BeholderPeople.Assessment.possible
    @State private var reason = ""
    @State private var evidence = ""
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    init(research: BeholderModel, target: Target? = nil) {
        self.research = research
        let preferred = target?.preferredPersonID.flatMap { id in research.people.people.first { $0.id == id }?.id }
        _selected = State(initialValue: preferred ?? (research.people.people.count == 1 ? research.people.people.first?.id : nil))
        _draft = State(initialValue: target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.space3) {
            HStack {
                Text("PEOPLE IN THIS CASE").hudType(.data)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Group accounts using evidence you have reviewed. A matching handle alone does not establish who owns it.")
                .foregroundStyle(HUD.inkMuted)
            if research.includesImportedObservations {
                Text(
                    "This case includes imported claims. Stored source checks and owner assessments have not been independently rechecked."
                )
                .font(.caption).foregroundStyle(HUD.warn)
            }
            HStack {
                TextField("Person label", text: $name).textFieldStyle(.roundedBorder)
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
                editor(draft)
            }
            if let problem {
                Text(problem).foregroundStyle(HUD.warn)
            }
            if let person = research.people.people.first(where: { $0.id == selected }) {
                Text("\(person.links.count) ACCOUNTS · " + person.name).hudType(.data)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: HUD.space3) {
                        ForEach(person.links) { link in
                            VStack(alignment: .leading, spacing: HUD.space2) {
                                HStack {
                                    Text(link.finding.provider.title + " · @" + link.username).font(.headline)
                                    Spacer()
                                    Text(link.assessment.title).font(.caption).foregroundStyle(HUD.primary)
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
                                if let source = link.finding.sourceURL ?? link.finding.preparedProfileURL {
                                    Text(verbatim: source.absoluteString).textSelection(.enabled)
                                }
                                HStack {
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
                            .font(.caption).padding(HUD.space3).background(HUD.surface)
                        }
                    }
                }.frame(maxHeight: 250)
                if person.links.isEmpty {
                    Text("Search a handle, then choose Link to person on a result.").foregroundStyle(HUD.inkMuted)
                }
            }
            Text("Kept in memory only. Export the case before closing Aegis. Evidence URLs are stored, never fetched.")
                .font(.caption).foregroundStyle(HUD.inkMuted)
        }
        .padding(HUD.space4).frame(width: 680, alignment: .leading)
        .foregroundStyle(HUD.ink).background(HUD.void)
        .onChange(of: selected) {
            if draft?.originalPersonID != nil {
                draft = nil
            }
            assessment = .possible; reason = ""; evidence = ""; problem = nil
        }
    }

    private func editor(_ target: Target) -> some View {
        VStack(alignment: .leading, spacing: HUD.space2) {
            Text("LINK " + target.finding.provider.title + " · @" + target.username).hudType(.data)
            Text("To: " + (research.people.people.first(where: { $0.id == selected })?.name ?? "Select a person"))
                .font(.headline)
            Picker("Assessment", selection: $assessment) {
                ForEach(BeholderPeople.Assessment.allCases) { Text($0.title).tag($0) }
            }
            TextField("Why do you link or rule out this account?", text: $reason)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Account link explanation")
            TextField("Public evidence URL (required for support)", text: $evidence).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Account link evidence URL")
            HStack {
                Button("Save assessment") {
                    perform {
                        guard let selected else { throw BeholderPeople.Problem.missing }
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
