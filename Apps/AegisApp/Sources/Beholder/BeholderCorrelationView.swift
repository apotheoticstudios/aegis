import SwiftUI

/// Evidence stays in the current case. No field here participates in a network request.
struct BeholderCorrelationView: View {
    let research: BeholderModel
    let onReview: (BeholderPeopleView.Target) -> Void
    /// Shown in the dashboard's Evidence tab rather than a sheet: no Done button, fills the tab.
    let embedded: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var personID: UUID?
    @State private var accountID: String?
    @State private var filter = ""
    @State private var tab: Int

    init(
        research: BeholderModel,
        personID: UUID? = nil,
        accountID: String? = nil,
        embedded: Bool = false,
        onReview: @escaping (BeholderPeopleView.Target) -> Void = { _ in }
    ) {
        self.research = research
        self.onReview = onReview
        self.embedded = embedded
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
            if !embedded {
                HStack {
                    Text("IDENTIFIER EVIDENCE").hudType(.data)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            Text("Compare already-held public evidence. Shared, recycled or business identifiers can belong to several people.")
                .hudType(.caption).foregroundStyle(HUD.inkMuted)
            if research.includesImportedObservations {
                Text("This case includes imported claims; source URLs and observation times have not been independently rechecked.")
                    .hudType(.caption).foregroundStyle(HUD.warn)
            }
            HUDSegmented(
                label: "Evidence section",
                options: [
                    HUDOption(value: 0, label: "Person and leads"),
                    HUDOption(value: 1, label: "Account archive", meta: "\(research.correlation.accounts.count)"),
                ],
                value: $tab
            )
            if tab == 0 {
                personEvidence
            } else {
                accountEvidence
            }
        }
        .padding(embedded ? 0 : HUD.space4)
        .frame(width: embedded ? nil : 760, height: embedded ? nil : 620)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil, alignment: .topLeading)
        .foregroundStyle(HUD.ink).background(embedded ? AnyShapeStyle(.clear) : AnyShapeStyle(HUD.void)).beholderStyle()
    }

    private var personEvidence: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HUD.space3) {
                BeholderMenuPicker(
                    label: "Person",
                    placeholder: "Choose a person",
                    options: research.people.people.map { ($0.id, $0.name) },
                    selection: $personID
                )
                .padding(.top, HUD.space3)
                if let person {
                    Text("Known public identifiers for \(person.name)").hudType(.label)
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
                    .hudType(.caption).foregroundStyle(HUD.inkMuted)
                    let leads = research.correlation.leads(for: person, people: research.people.people)
                    if leads.isEmpty {
                        Text(
                            "No matching account evidence yet. Record an identifier on an account in the archive, or search another username."
                        )
                        .hudType(.caption)
                    }
                    ForEach(leads) { lead in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(lead.account.finding.provider.title + " · @" + lead.account.username).hudType(.label)
                                Spacer()
                                Button("Review account link…") {
                                    onReview(.init(
                                        username: lead.account.username,
                                        finding: lead.account.finding,
                                        preferredPersonID: person.id
                                    ))
                                }
                            }
                            Text("\(lead.identifierCount) exact identifier overlap(s); ownership is unverified.").hudType(.caption)
                            attemptNote(lead.account)
                            ForEach(lead.overlaps) { overlap in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: overlap.evidence.identifier.value).textSelection(.enabled)
                                    Text("Account evidence: " + overlap.evidence.source.absoluteString).textSelection(.enabled)
                                    Text("Reference: " + overlap.referenceURL.absoluteString).textSelection(.enabled)
                                    Text(
                                        "Account observed \(overlap.evidence.observedAt.formatted()); reference \(overlap.referenceDate.formatted())"
                                    )
                                }.hudType(.caption).foregroundStyle(HUD.inkMuted)
                            }
                        }.padding(HUD.space3).background(HUD.surface)
                    }
                } else {
                    Text("Create a person in People, then select them here. Possible and ruled-out links never seed new matches.")
                        .hudType(.caption).foregroundStyle(HUD.inkMuted)
                }
            }.padding(HUD.space3)
        }
    }

    private var accountEvidence: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HUD.space3) {
                TextField("Filter archived accounts", text: $filter).modifier(BeholderField())
                BeholderMenuPicker(
                    label: "Account",
                    placeholder: "Choose an account",
                    options: research.correlation.accounts.filter {
                        filter.isEmpty || ($0.finding.provider.title + " " + $0.username).localizedCaseInsensitiveContains(filter)
                    }.map { ($0.id, $0.finding.provider.title + " · @" + $0.username) },
                    selection: $accountID
                )
                if let account {
                    Text(account.finding.provider.title + " · @" + account.username).hudType(.label)
                    BeholderEvidenceExplanationView(finding: account.finding)
                    attemptNote(account)
                    Text(
                        "Record only an identifier explicitly published as this account's contact information. A mention in a post or biography may refer to someone else."
                    )
                    .hudType(.caption).foregroundStyle(HUD.inkMuted)
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
            .hudType(.caption).foregroundStyle(HUD.inkMuted)
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
            }.hudType(.caption)
            Spacer()
            Button("Remove", action: remove)
        }
    }
}

struct BeholderIdentifierEditor: View {
    let save: (BeholderIdentifier, String) throws -> Void
    @State private var kind = BeholderIdentifier.Kind.email
    @State private var region = BeholderQueryPlanner.PhoneRegion.international
    @State private var input = ""
    @State private var source = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HUDSegmented(
                    label: "Type",
                    options: [HUDOption(value: BeholderIdentifier.Kind.email, label: "Email"), HUDOption(value: .phone, label: "Phone")],
                    value: $kind,
                    small: true
                )
                if kind == .phone {
                    HUDSegmented(
                        label: "Format",
                        options: BeholderQueryPlanner.PhoneRegion.allCases.map { HUDOption(value: $0, label: $0.rawValue) },
                        value: $region,
                        small: true
                    )
                }
            }
            TextField(kind == .email ? "Public email" : "Complete phone number", text: $input).modifier(BeholderField())
            TextField("Public HTTPS evidence URL", text: $source).modifier(BeholderField())
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
                Text(problem).hudType(.caption).foregroundStyle(HUD.warn)
            }
        }
    }
}
