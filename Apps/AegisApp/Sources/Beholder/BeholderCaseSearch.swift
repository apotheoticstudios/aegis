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
        let people: [PersonHit]

        var total: Int {
            hits.count
        }

        var providers: [BeholderProvider] {
            Set(hits.map(\.account.finding.provider)).sorted { ($0.title, $0.rawValue) < ($1.title, $1.rawValue) }
        }

        func accountPage(provider: BeholderProvider?, status: BeholderFinding.Status?, index: Int) -> AccountPage {
            let matches = hits.filter {
                (provider == nil || $0.account.finding.provider == provider)
                    && (status == nil || $0.account.finding.status == status)
            }
            let size = 6
            let lastPage = max(0, matches.count - 1) / size
            let page = max(0, min(index, lastPage))
            let start = page * size
            let end = min(start + size, matches.count)
            return .init(hits: matches[start ..< end], index: page, total: matches.count)
        }
    }

    struct AccountPage {
        let hits: ArraySlice<Hit>
        let index: Int
        let total: Int

        var hasNext: Bool {
            hits.endIndex < total
        }
    }

    struct PersonHit: Identifiable {
        let person: BeholderPeople.Person
        let reason: Reason
        var id: UUID {
            person.id
        }
    }

    enum Problem: Error {
        case input
        var message: String {
            "Enter a complete value for this input type. For national phone numbers, choose Australia explicitly."
        }
    }

    /// Reject identifier-shaped input before it can reach an automatic username source.
    static func username(_ input: String) -> String? {
        guard input.utf8.count <= 512, usernameProblem(input) == nil,
              input.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                      && $0.properties.generalCategory != .format
              }) else { return nil }
        return BeholderProvider.username(input)
    }

    static func usernameProblem(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") {
            value.removeFirst()
        }
        if value.contains("@") {
            return "This looks like an email address. Choose Email mode first."
        }
        if BeholderIPContext.inspect(value) != nil {
            return "This looks like an IP address. Choose IP address mode first."
        }
        if value.lowercased().hasPrefix("tel:") {
            value = String(value.dropFirst(4))
        }
        let digits = value.filter { $0.isASCII && $0.isNumber }
        if (8 ... 15).contains(digits.count), value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "+0123456789 ().-").contains) {
            return "This looks like a phone number. Choose Phone mode first."
        }
        return nil
    }

    /// Only structured profile names, explicit identifier evidence and supported owner links are searched.
    /// Biographies and arbitrary mentions cannot identify an account owner.
    static func compute(
        input: String, kind: Kind, region: BeholderQueryPlanner.PhoneRegion = .international,
        store: BeholderCorrelation, people: BeholderPeople
    ) throws -> Report {
        let (query, identifier) = try normalized(input, kind: kind, region: region)
        var accounts: [String: BeholderCorrelation.Account] = [:]
        for account in store.accounts where accounts[account.id] == nil {
            accounts[account.id] = account
        }
        var ownerReasons: [String: [Reason]] = [:]
        var personReasons: [UUID: [Reason]] = [:]
        let hintsByPerson = Dictionary(grouping: store.hints, by: \.personID)
        for person in people.people {
            let nameOrder = kind == .name ? nameMatch(query, person.name) : nil
            if let nameOrder {
                let label = nameOrder == 0 ? "Saved person label matches" : "Saved person label shares name words"
                personReasons[person.id] = [.init(
                    id: "label", label: label, value: person.name, source: nil, date: nil, order: nameOrder
                )]
            }
            let references = (hintsByPerson[person.id] ?? []).compactMap { hint -> Reason? in
                guard let identifier, let order = matching(identifier, hint.identifier) else { return nil }
                return .init(
                    id: "hint:" + hint.id.uuidString,
                    label: "Recorded person reference" + (order == 1 ? "; email case differs" : ""),
                    value: hint.identifier.value, source: hint.source, date: hint.observedAt, order: order
                )
            }
            if !references.isEmpty {
                personReasons[person.id] = references
            }
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
                for reference in references {
                    ownerReasons[link.accountKey, default: []].append(.init(
                        id: reference.id,
                        label: "Owner reference for \(person.name); account link supported by you" +
                            (reference.order == 1 ? "; email case differs" : ""),
                        value: reference.value, source: reference.source, date: reference.date, order: reference.order
                    ))
                }
            }
        }
        let grouped = Dictionary(grouping: store.evidence, by: \.accountID)
        let hits = accounts.values.compactMap { account -> Hit? in
            guard [.candidate, .manual, .noResult].contains(account.finding.status) else { return nil }
            var reasons = ownerReasons[account.id] ?? []
            if kind == .username, account.id == BeholderCorrelation.key(account.finding.provider, query) {
                reasons.append(.init(
                    id: "saved-handle", label: "Saved profile handle matches", value: account.username,
                    source: account.finding.sourceURL, date: account.finding.checkedAt, order: 0
                ))
            }
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
        let personHits = matchingPeople(people.people, directReasons: personReasons, accountHits: hits)
        return Report(query: query, kind: kind, hits: hits, people: personHits)
    }

    private static func normalized(
        _ input: String, kind: Kind, region: BeholderQueryPlanner.PhoneRegion
    ) throws -> (String, BeholderIdentifier?) {
        switch kind {
        case .username:
            guard let value = username(input) else { throw Problem.input }
            return (value, nil)
        case .name:
            guard case let .success(plan) = BeholderQueryPlanner.build(input: input, kind: .name) else { throw Problem.input }
            return (plan.seed, nil)
        case .email, .phone:
            guard let value = BeholderIdentifier(input: input, kind: kind == .email ? .email : .phone, region: region)
            else { throw Problem.input }
            return (value.value, value)
        case .ip: throw Problem.input
        }
    }

    private static func matchingPeople(
        _ people: [BeholderPeople.Person], directReasons: [UUID: [Reason]], accountHits: [Hit]
    ) -> [PersonHit] {
        let matched = Dictionary(uniqueKeysWithValues: accountHits.map { ($0.id, $0) })
        return people.compactMap { person -> PersonHit? in
            let accountReasons = person.links.compactMap { link -> Reason? in
                guard link.assessment == .supported, let hit = matched[link.accountKey], let first = hit.reasons.first else { return nil }
                let title = hit.historical ? "Supported account matched earlier evidence" : "Supported account matched"
                return .init(
                    id: link.accountKey, label: title, value: link.finding.provider.title + " · @" + link.username,
                    source: link.evidenceURL, date: link.assessedAt, order: first.order + (hit.historical ? 3 : 0)
                )
            }
            // Prefer a direct reference when it matches as closely as a supported account.
            let reasons = (directReasons[person.id] ?? []) + accountReasons
            guard let best = reasons.min(by: { $0.order < $1.order }) else { return nil }
            return .init(person: person, reason: best)
        }.sorted { ($0.reason.order, $0.person.name, $0.id.uuidString) < ($1.reason.order, $1.person.name, $1.id.uuidString) }
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
        let leftWords = left.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.sorted()
        let rightWords = right.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.sorted()
        guard !leftWords.isEmpty, leftWords.allSatisfy({ $0.count >= 2 }) else { return nil }
        if leftWords.count > 1, leftWords == rightWords {
            return 1
        }
        let counts = Dictionary(grouping: rightWords, by: { $0 })
        return Dictionary(grouping: leftWords, by: { $0 }).allSatisfy { word, occurrences in
            occurrences.count <= (counts[word]?.count ?? 0)
        } ? 2 : nil
    }
}
