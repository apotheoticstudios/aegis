import Foundation

/// A local evidence overview, not an identity verdict. No transport, memory or persistent state.
enum BeholderInvestigation {
    struct Detail: Identifiable {
        let id: String
        let identifier: BeholderIdentifier
        let source: URL
        let date: Date
        let origin: String
        let historical: Bool
        let pending: Bool
        let sharedWith: [String]
    }

    struct Summary {
        let identifiers: [IdentifierGroup]
        let identifierCount: Int
        let detailCount: Int
        let leads: [BeholderCorrelation.Lead]
        let leadCount: Int
        let nextStep: String

        var details: [Detail] {
            identifiers.flatMap(\.references)
        }
    }

    struct IdentifierGroup: Identifiable {
        let identifier: BeholderIdentifier
        let references: [Detail]
        let referenceCount: Int
        var id: BeholderIdentifier {
            identifier
        }
    }

    static func summarize(_ person: BeholderPeople.Person, people: BeholderPeople, store: BeholderCorrelation) -> Summary {
        let supported = Set(person.links.filter { $0.assessment == .supported }.map(\.accountKey))
        let accounts = Dictionary(store.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var references: [UUID: Set<BeholderIdentifier>] = [:]
        for other in people.people {
            let keys = Set(other.links.filter { $0.assessment == .supported }.map(\.accountKey))
            references[other.id] = Set(store.hints.filter { $0.personID == other.id }.map(\.identifier))
                .union(store.evidence.filter { keys.contains($0.accountID) }.map(\.identifier))
        }
        func shared(_ value: BeholderIdentifier) -> [String] {
            people.people.filter { $0.id != person.id && references[$0.id]?.contains(value) == true }
                .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }.map(\.name)
        }
        var details = store.hints.filter { $0.personID == person.id }.map {
            Detail(
                id: "hint:" + $0.id.uuidString,
                identifier: $0.identifier,
                source: $0.source,
                date: $0.observedAt,
                origin: "Reference recorded by you",
                historical: false,
                pending: false,
                sharedWith: shared($0.identifier)
            )
        }
        for item in store.evidence where supported.contains(item.accountID) {
            guard let account = accounts[item.accountID] else { continue }
            details.append(Detail(
                id: "evidence:" + item.id.uuidString, identifier: item.identifier, source: item.source, date: item.observedAt,
                origin: (item.origin == .publicField ? "Published on " : "Recorded by you for ") +
                    account.finding.provider.title + " @" + account.username + "; account supported by you",
                historical: account.finding.status == .noResult, pending: account.pending, sharedWith: shared(item.identifier)
            ))
        }
        let groups = Dictionary(grouping: details, by: \.identifier).map { identifier, sources in
            let sorted = sources.sorted {
                if $0.date != $1.date {
                    return $0.date > $1.date
                }
                return ($0.source.absoluteString, $0.id) < ($1.source.absoluteString, $1.id)
            }
            return IdentifierGroup(identifier: identifier, references: Array(sorted.prefix(5)), referenceCount: sources.count)
        }.sorted { $0.identifier < $1.identifier }
        let leads = store.leads(for: person, people: people.people)
        let next = details.isEmpty ? "Add a public email or phone reference with its source below."
            : !leads.isEmpty ? "Review the account leads that share your reference identifiers."
            : person.links.contains { $0.assessment == .possible } ? "Review your possible accounts before supporting a link."
            : "Search a username you know, or type a name, email or phone to prepare a public browser search."
        return Summary(
            identifiers: Array(groups.prefix(20)),
            identifierCount: groups.count,
            detailCount: details.count,
            leads: Array(leads.prefix(20)),
            leadCount: leads.count,
            nextStep: next
        )
    }
}
