import Foundation

/// Explicit input modes prevent a personal identifier from silently becoming a username lookup.
enum BeholderCaseSearch {
    enum Kind: String, CaseIterable, Identifiable {
        case username = "Username", name = "Name", email = "Email", phone = "Phone", ip = "IP address"
        var id: String {
            rawValue
        }
    }

    struct Reason: Equatable, Identifiable {
        let id: String
        let label: String
        let value: String
        let source: URL?
        let date: Date?
        let order: Int
    }

    struct Hit: Identifiable {
        let account: BeholderCorrelation.Account
        let reasons: [Reason]
        let totalReasons: Int
        var id: String {
            account.id
        }

        var historical: Bool {
            account.finding.status == .noResult
        }
    }

    struct Report {
        let query: String
        let kind: Kind
        let hits: [Hit]
        let total: Int
    }

    enum Problem: Error {
        case input
        var message: String {
            "Enter a complete value for this input type. For national phone numbers, choose Australia explicitly."
        }
    }

    /// Only structured profile names, explicit identifier evidence and supported owner links are searched.
    /// Biographies and arbitrary mentions cannot identify an account owner.
    static func compute(
        input: String, kind: Kind, region: BeholderQueryPlanner.PhoneRegion = .international,
        store: BeholderCorrelation, people: BeholderPeople
    ) throws -> Report {
        let identifier: BeholderIdentifier?
        let query: String
        switch kind {
        case .name:
            guard case let .success(plan) = BeholderQueryPlanner.build(input: input, kind: .name) else { throw Problem.input }
            query = plan.seed; identifier = nil
        case .email, .phone:
            guard let value = BeholderIdentifier(input: input, kind: kind == .email ? .email : .phone, region: region)
            else { throw Problem.input }
            query = value.value; identifier = value
        default: throw Problem.input
        }
        var accounts: [String: BeholderCorrelation.Account] = [:]
        for account in store.accounts where accounts[account.id] == nil {
            accounts[account.id] = account
        }
        var ownerReasons: [String: [Reason]] = [:]
        for person in people.people {
            let nameOrder = kind == .name ? nameMatch(query, person.name) : nil
            let hints = identifier
                .map { sought in store.hints.filter { $0.personID == person.id && matching(sought, $0.identifier) != nil } } ?? []
            for link in person.links where link.assessment == .supported {
                if accounts[link.accountKey] == nil {
                    accounts[link.accountKey] = .init(id: link.accountKey, username: link.username, finding: link.finding)
                }
                if let order = nameOrder {
                    ownerReasons[link.accountKey, default: []].append(.init(
                        id: "person:" + person.id.uuidString, label: "Owner-supported person label", value: person.name,
                        source: link.evidenceURL, date: link.assessedAt, order: order
                    ))
                }
                for hint in hints {
                    guard let identifier, let order = matching(identifier, hint.identifier) else { continue }
                    ownerReasons[link.accountKey, default: []].append(.init(
                        id: "hint:" + hint.id.uuidString,
                        label: "Owner reference for \(person.name); account link supported by you" +
                            (order == 1 ? "; email case differs" : ""),
                        value: hint.identifier.value, source: hint.source, date: hint.observedAt,
                        order: order
                    ))
                }
            }
        }
        let grouped = Dictionary(grouping: store.evidence, by: \.accountID)
        let hits = accounts.values.compactMap { account -> Hit? in
            guard !account.pending, [.candidate, .manual, .noResult].contains(account.finding.status) else { return nil }
            var reasons = ownerReasons[account.id] ?? []
            if kind == .name, account.finding.status == .candidate,
               let name = account.finding.fields["Display name"], let order = nameMatch(query, name)
            {
                reasons.append(.init(
                    id: "profile-name",
                    label: order == 0 ? "Profile display name matches" : order == 1 ? "Profile name words match" :
                        "Partial name match; verify manually",
                    value: name,
                    source: account.finding.sourceURL,
                    date: account.finding.checkedAt,
                    order: order
                ))
            }
            if let identifier {
                for item in grouped[account.id] ?? [] {
                    guard let order = matching(identifier, item.identifier) else { continue }
                    let label = order == 1 ? "Email differs only in local-part case; verify manually"
                        : item.origin == .publicField ? "Structured public contact field" : "Public identifier recorded by you"
                    reasons.append(.init(
                        id: "evidence:" + item.id.uuidString,
                        label: label,
                        value: item.identifier.value,
                        source: item.source,
                        date: item.observedAt,
                        order: order
                    ))
                }
            }
            reasons.sort { ($0.order, $0.id) < ($1.order, $1.id) }
            return reasons.isEmpty ? nil : Hit(account: account, reasons: Array(reasons.prefix(20)), totalReasons: reasons.count)
        }.sorted {
            let lhs = ($0.historical ? 1 : 0, $0.reasons.first?.order ?? 0, $0.id)
            let rhs = ($1.historical ? 1 : 0, $1.reasons.first?.order ?? 0, $1.id)
            return lhs < rhs
        }
        return Report(query: query, kind: kind, hits: Array(hits.prefix(100)), total: hits.count)
    }

    private static func matching(_ query: BeholderIdentifier, _ candidate: BeholderIdentifier) -> Int? {
        if query == candidate {
            return 0
        }
        return query.kind == .email && candidate.kind == .email && query.value.lowercased() == candidate.value.lowercased() ? 1 : nil
    }

    private static func nameMatch(_ query: String, _ candidate: String) -> Int? {
        func folded(_ input: String) -> String {
            input.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let left = folded(query), right = folded(candidate)
        if left == right {
            return 0
        }
        let a = left.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.sorted()
        let b = right.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.sorted()
        if a.count > 1, a == b {
            return 1
        }
        return !a.isEmpty && Set(a).isSubset(of: Set(b)) ? 2 : nil
    }
}
