import SwiftUI

/// Evidence stays in the current case. No field here participates in a network request.
struct BeholderCorrelationView: View {
    let research: BeholderModel
    let onReview: (BeholderPeopleView.Target) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var personID: UUID?
    @State private var accountID: String?
    @State private var filter = ""
    @State private var tab: Int

    init(
        research: BeholderModel,
        personID: UUID? = nil,
        accountID: String? = nil,
        onReview: @escaping (BeholderPeopleView.Target) -> Void = { _ in }
    ) {
        self.research = research
        self.onReview = onReview
        _personID = State(initialValue: personID)
        _accountID = State(initialValue: accountID)
        _tab = State(initialValue: accountID == nil ? 0 : 1)
    }

    private var person: BeholderPeople.Person? {
        research.people.people.first { $0.id == personID }
    }

    private var account: BeholderCorrelation.Account? {
        research.correlation.accounts.first { $0.id == accountID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HUD.space3) {
            HStack {
                Text("IDENTIFIER EVIDENCE").hudType(.data)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Compare already-held public evidence. Shared, recycled or business identifiers can belong to several people.")
                .font(.caption).foregroundStyle(HUD.inkMuted)
            if research.includesImportedObservations {
                Text("This case includes imported claims; source URLs and observation times have not been independently rechecked.")
                    .font(.caption).foregroundStyle(HUD.warn)
            }
            Picker("Evidence section", selection: $tab) {
                Text("Person and leads").tag(0)
                Text("Account archive (\(research.correlation.accounts.count))").tag(1)
            }.pickerStyle(.segmented)
            if tab == 0 {
                personEvidence
            } else {
                accountEvidence
            }
        }
        .padding(HUD.space4).frame(width: 760, height: 620).foregroundStyle(HUD.ink).background(HUD.void)
    }

    private var personEvidence: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HUD.space3) {
                Picker("Person", selection: $personID) {
                    Text("Choose a person").tag(nil as UUID?)
                    ForEach(research.people.people) { Text($0.name).tag(Optional($0.id)) }
                }.padding(.top, HUD.space3)
                if let person {
                    Text("Known public identifiers for \(person.name)").font(.headline)
                    BeholderIdentifierEditor { identifier, source in
                        try research.correlation.identify(personID: person.id, identifier: identifier, source: source)
                    }.id(person.id)
                    ForEach(research.correlation.hints.filter { $0.personID == person.id }) { hint in
                        evidenceRow(hint.identifier, url: hint.source, date: hint.observedAt, label: "Recorded by you") {
                            research.correlation.removeHint(hint.id)
                        }
                    }
                    Divider()
                    Text("REVIEWABLE LEADS").hudType(.data)
                    Text(
                        "Exact overlaps with your reference identifiers or supported account evidence. No automatic links. Email local-part case is preserved."
                    )
                    .font(.caption).foregroundStyle(HUD.inkMuted)
                    let leads = research.correlation.leads(for: person, people: research.people.people)
                    if leads.isEmpty {
                        Text(
                            "No matching account evidence yet. Record an identifier on an account in the archive, or search another username."
                        )
                        .font(.caption)
                    }
                    ForEach(leads) { lead in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(lead.account.finding.provider.title + " · @" + lead.account.username).font(.headline)
                                Spacer()
                                Button("Review account link…") {
                                    onReview(.init(
                                        username: lead.account.username,
                                        finding: lead.account.finding,
                                        preferredPersonID: person.id
                                    ))
                                }
                            }
                            Text("\(lead.identifierCount) exact identifier overlap(s); ownership is unverified.").font(.caption)
                            attemptNote(lead.account)
                            ForEach(lead.overlaps) { overlap in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: overlap.evidence.identifier.value).textSelection(.enabled)
                                    Text("Account evidence: " + overlap.evidence.source.absoluteString).textSelection(.enabled)
                                    Text("Reference: " + overlap.referenceURL.absoluteString).textSelection(.enabled)
                                    Text(
                                        "Account observed \(overlap.evidence.observedAt.formatted()); reference \(overlap.referenceDate.formatted())"
                                    )
                                }.font(.caption).foregroundStyle(HUD.inkMuted)
                            }
                        }.padding(HUD.space3).background(HUD.surface)
                    }
                } else {
                    Text("Create a person in People, then select them here. Possible and ruled-out links never seed new matches.")
                        .font(.caption).foregroundStyle(HUD.inkMuted)
                }
            }.padding(HUD.space3)
        }
    }

    private var accountEvidence: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HUD.space3) {
                TextField("Filter archived accounts", text: $filter).textFieldStyle(.roundedBorder)
                Picker("Account", selection: $accountID) {
                    Text("Choose an account").tag(nil as String?)
                    ForEach(research.correlation.accounts.filter {
                        filter.isEmpty || ($0.finding.provider.title + " " + $0.username).localizedCaseInsensitiveContains(filter)
                    }) { item in
                        Text(item.finding.provider.title + " · @" + item.username).tag(Optional(item.id))
                    }
                }
                if let account {
                    Text(account.finding.provider.title + " · @" + account.username).font(.headline)
                    BeholderEvidenceExplanationView(finding: account.finding)
                    attemptNote(account)
                    Text(
                        "Record only an identifier explicitly published as this account's contact information. A mention in a post or biography may refer to someone else."
                    )
                    .font(.caption).foregroundStyle(HUD.inkMuted)
                    BeholderIdentifierEditor { identifier, source in
                        try research.correlation.record(accountID: account.id, identifier: identifier, source: source)
                    }.id(account.id)
                    ForEach(research.correlation.evidence.filter { $0.accountID == account.id }) { item in
                        evidenceRow(
                            item.identifier, url: item.source, date: item.observedAt,
                            label: item.origin == .publicField ? "Structured public API field" : "Recorded by you"
                        ) { research.correlation.removeEvidence(item.id) }
                    }
                }
            }.padding(HUD.space3)
        }
    }

    @ViewBuilder private func attemptNote(_ account: BeholderCorrelation.Account) -> some View {
        if let attempt = account.latestAttempt {
            Text(
                "Latest attempt: \(attempt.finding.status.title). Earlier dated evidence is retained; this attempt did not establish a change."
            )
            .font(.caption).foregroundStyle(HUD.inkMuted)
        }
    }

    private func evidenceRow(
        _ identifier: BeholderIdentifier,
        url: URL,
        date: Date,
        label: String,
        remove: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: identifier.value).textSelection(.enabled)
                Text(label + " · " + date.formatted()).foregroundStyle(HUD.inkMuted)
                Text(verbatim: url.absoluteString).textSelection(.enabled).foregroundStyle(HUD.inkMuted)
            }.font(.caption)
            Spacer()
            Button("Remove", action: remove)
        }
    }
}

private struct BeholderIdentifierEditor: View {
    let save: (BeholderIdentifier, String) throws -> Void
    @State private var kind = BeholderIdentifier.Kind.email
    @State private var region = BeholderQueryPlanner.PhoneRegion.international
    @State private var input = ""
    @State private var source = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Type", selection: $kind) {
                    Text("Email").tag(BeholderIdentifier.Kind.email)
                    Text("Phone").tag(BeholderIdentifier.Kind.phone)
                }.frame(width: 180)
                if kind == .phone {
                    Picker("Format", selection: $region) {
                        ForEach(BeholderQueryPlanner.PhoneRegion.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            TextField(kind == .email ? "Public email" : "Complete phone number", text: $input)
            TextField("Public HTTPS evidence URL", text: $source)
            Button("Record identifier locally") {
                guard let identifier = BeholderIdentifier(input: input, kind: kind, region: region) else {
                    problem = BeholderCorrelation.Problem.input.message; return
                }
                do {
                    try save(identifier, source)
                    input = ""; source = ""; problem = nil
                } catch { problem = (error as? BeholderCorrelation.Problem)?.message ?? "The evidence could not be recorded." }
            }.disabled(input.isEmpty || source.isEmpty)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(HUD.warn)
            }
        }.textFieldStyle(.roundedBorder)
    }
}
