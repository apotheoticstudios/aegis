import SwiftUI

/// One place to inspect references and leads for a person. Only explicit local edits are offered.
struct BeholderInvestigationView: View {
    let research: BeholderModel
    let person: BeholderPeople.Person
    let onReview: (BeholderPeopleView.Target) -> Void
    @State private var saveNote: String?

    var body: some View {
        let summary = BeholderInvestigation.summarize(person, people: research.people, store: research.correlation)
        VStack(alignment: .leading, spacing: HUD.space3) {
            Text(person.name).hudType(.bodyStrong).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: HUD.space3) {
                ForEach([BeholderPeople.Assessment.supported, .possible, .ruledOut]) { assessment in
                    Text("\(person.links.filter { $0.assessment == assessment }.count) " + assessment.title).hudType(.caption)
                }
            }
            Text("Next: " + summary.nextStep).foregroundStyle(HUD.primary)
            if let saveNote {
                Text(saveNote).hudType(.caption).foregroundStyle(HUD.primary)
            }
            Text("References and supported account details are evidence to inspect, not automatically verified facts about a person.")
                .hudType(.caption).foregroundStyle(HUD.inkMuted)
            DisclosureGroup("Add a public email or phone reference") {
                BeholderIdentifierEditor { identifier, source in
                    try research.correlation.identify(personID: person.id, identifier: identifier, source: source)
                }.id(person.id)
            }
            if !summary.identifiers.isEmpty {
                Text("PUBLIC DETAILS · \(summary.identifierCount) IDENTIFIERS · \(summary.detailCount) REFERENCES").hudType(.data)
                ForEach(summary.identifiers) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: group.identifier.value).hudType(.bodyStrong).textSelection(.enabled)
                        if let shared = group.references.first?.sharedWith, !shared.isEmpty {
                            Text("Also referenced under " + shared
                                .joined(separator: ", ") + ". A shared identifier is not unique identity evidence.")
                                .foregroundStyle(HUD.warn)
                        }
                        DisclosureGroup("Sources and times · \(group.referenceCount) references") {
                            ForEach(group.references) { detail in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(detail.origin).foregroundStyle(HUD.inkMuted)
                                    Text(verbatim: detail.source.absoluteString).textSelection(.enabled)
                                    Text("Source recorded " + detail.date.formatted()).foregroundStyle(HUD.inkMuted)
                                    if detail.historical {
                                        Text("Historical: this account's latest completed check had no public result.")
                                            .foregroundStyle(HUD.warn)
                                    }
                                    if detail.pending {
                                        Text("Re-check pending; the recorded evidence is shown above.").foregroundStyle(HUD.inkMuted)
                                    }
                                }
                            }
                            if group.referenceCount > group.references.count {
                                Text("Showing the latest 5 references; see Evidence for all.").foregroundStyle(HUD.inkMuted)
                            }
                        }
                    }.hudType(.caption).padding(HUD.space2).frame(maxWidth: .infinity, alignment: .leading).background(HUD.surface)
                }
                if summary.identifierCount > summary.identifiers.count {
                    Text("Showing the first 20 identifiers. The Evidence tab contains the full case.").hudType(.caption)
                }
            }
            if !summary.leads.isEmpty {
                Text("ACCOUNTS TO INVESTIGATE · \(summary.leadCount)").hudType(.data)
                ForEach(summary.leads) { lead in
                    VStack(alignment: .leading, spacing: HUD.space2) {
                        HStack {
                            Text(lead.account.finding.provider.title + " · @" + lead.account.username).hudType(.label)
                            Spacer()
                            Button("Save as possible") {
                                do {
                                    let added = try research.savePossible(
                                        personID: person.id,
                                        username: lead.account.username,
                                        finding: lead.account.finding
                                    )
                                    saveNote = added ? "Saved as possible for " + person.name + ". Review it in the accounts below."
                                        : "An assessment is already saved for this account or a case variant. It was kept."
                                } catch { saveNote = (error as? BeholderPeople.Problem)?.message ?? "The account could not be saved." }
                            }
                            Button("Review for " + person.name) {
                                onReview(.init(
                                    username: lead.account.username,
                                    finding: lead.account.finding,
                                    preferredPersonID: person.id
                                ))
                            }
                        }
                        Text("\(lead.identifierCount) distinct identifier overlap(s); ownership remains unverified.").hudType(.caption)
                        ForEach(Array(lead.overlaps.prefix(5))) { overlap in
                            Text(overlap.evidence.identifier.value + " · account: " + overlap.evidence.source.absoluteString +
                                " (" + overlap.evidence.observedAt.formatted() + ") · reference: " + overlap.referenceURL.absoluteString +
                                " (" + overlap.referenceDate.formatted() + ")").hudType(.caption).textSelection(.enabled)
                        }
                        if lead.overlaps.count > 5 {
                            Text("Showing 5 of \(lead.overlaps.count) references; see Evidence for all.").hudType(.caption)
                        }
                    }.padding(HUD.space3).background(HUD.surface)
                }
                if summary.leadCount > summary.leads.count {
                    Text("Showing the first 20 account leads; see Evidence for all.").hudType(.caption)
                }
            }
        }.beholderStyle()
    }
}
