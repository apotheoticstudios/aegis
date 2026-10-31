import Foundation

/// Bounded local observations. A shared public identifier produces a lead, never a person merge.
struct BeholderCorrelation: Codable, Equatable, Sendable {
    struct Account: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let username: String
        var finding: BeholderFinding
    }

    struct Evidence: Codable, Equatable, Sendable, Identifiable {
        enum Origin: String, Codable, Sendable { case publicField, ownerRecorded }
        let id: UUID
        let accountID: String
        let identifier: BeholderIdentifier
        let source: URL
        let observedAt: Date
        let origin: Origin
    }

    struct Hint: Codable, Equatable, Sendable, Identifiable {
        let id: UUID
        let personID: UUID
        let identifier: BeholderIdentifier
        let source: URL
        let observedAt: Date
    }

    struct Overlap: Equatable, Identifiable {
        let evidence: Evidence
        let referenceURL: URL
        let referenceDate: Date
        var id: UUID {
            evidence.id
        }
    }

    struct Lead: Equatable, Identifiable {
        let account: Account
        let overlaps: [Overlap]
        var id: String {
            account.id
        }

        var identifierCount: Int {
            Set(overlaps.map(\.evidence.identifier)).count
        }
    }

    enum Problem: Error {
        case input, missing, capacity
        var message: String {
            switch self {
            case .input: "Use a complete email or phone number and a public HTTPS evidence URL."
            case .missing: "Choose an account or person in this case first."
            case .capacity: "This case has reached its evidence limit. Export it before starting another."
            }
        }
    }

    static let accountLimit = 500
    static let evidenceLimit = 2000
    private(set) var accounts: [Account] = []
    private(set) var evidence: [Evidence] = []
    private(set) var hints: [Hint] = []

    static func key(_ provider: BeholderProvider, _ username: String) -> String {
        provider.rawValue + ":" + (provider.isManual ? username : provider.lookupHandle(username))
    }

    /// A refresh replaces structured fields, so removed or stale public fields cannot keep producing leads.
    @discardableResult mutating func observe(username: String, finding: BeholderFinding) -> Bool {
        guard BeholderProvider.username(username) == username, finding.provider.supports(username) else { return false }
        let id = Self.key(finding.provider, username)
        let existing = accounts.firstIndex { $0.id == id }
        let eligible = finding.status == .candidate || finding.status == .manual
        guard eligible || existing != nil else { return true }
        guard eligible ? validAccount(username, finding) : finding.sourceURL == finding.provider.endpoint(username) else { return false }
        if let existing {
            accounts[existing] = Account(id: id, username: username, finding: finding)
        } else {
            guard accounts.count < Self.accountLimit else { return false }
            accounts.append(Account(id: id, username: username, finding: finding))
        }
        evidence.removeAll { $0.accountID == id && $0.origin == .publicField }
        // A biography mentioning an email/phone is not an account owner's declaration.
        if finding.status == .candidate, finding.provider == .github,
           let raw = finding.fields["Public email"], let identifier = BeholderIdentifier(input: raw, kind: .email),
           let source = finding.sourceURL, let date = finding.checkedAt, evidence.count < Self.evidenceLimit
        {
            evidence.append(Evidence(
                id: UUID(),
                accountID: id,
                identifier: identifier,
                source: source,
                observedAt: date,
                origin: .publicField
            ))
        }
        return true
    }

    mutating func record(accountID: String, identifier: BeholderIdentifier, source: String, now: Date = Date()) throws {
        guard accounts.contains(where: { $0.id == accountID }) else { throw Problem.missing }
        guard let url = BeholderPeople.evidenceURL(source) else { throw Problem.input }
        guard !evidence.contains(where: { $0.accountID == accountID && $0.identifier == identifier && $0.source == url }) else { return }
        guard evidence.count < Self.evidenceLimit else { throw Problem.capacity }
        evidence.append(Evidence(
            id: UUID(),
            accountID: accountID,
            identifier: identifier,
            source: url,
            observedAt: now,
            origin: .ownerRecorded
        ))
    }

    mutating func identify(personID: UUID, identifier: BeholderIdentifier, source: String, now: Date = Date()) throws {
        guard let url = BeholderPeople.evidenceURL(source) else { throw Problem.input }
        guard !hints.contains(where: { $0.personID == personID && $0.identifier == identifier && $0.source == url }) else { return }
        guard hints.count < 500 else { throw Problem.capacity }
        hints.append(Hint(id: UUID(), personID: personID, identifier: identifier, source: url, observedAt: now))
    }

    mutating func removeEvidence(_ id: UUID) {
        evidence.removeAll { $0.id == id }
    }

    mutating func removeHint(_ id: UUID) {
        hints.removeAll { $0.id == id }
    }

    /// Only owner-entered person references and supported accounts seed matches. Possible links never reinforce themselves.
    func leads(for person: BeholderPeople.Person) -> [Lead] {
        var references: [BeholderIdentifier: (URL, Date)] = [:]
        for hint in hints where hint.personID == person.id {
            if references[hint.identifier] == nil {
                references[hint.identifier] = (hint.source, hint.observedAt)
            }
        }
        let supported = Set(person.links.filter { $0.assessment == .supported }.map(\.accountKey))
        for item in evidence where supported.contains(item.accountID) {
            guard accounts.contains(where: { $0.id == item.accountID && [.candidate, .manual].contains($0.finding.status) })
            else { continue }
            if references[item.identifier] == nil {
                references[item.identifier] = (item.source, item.observedAt)
            }
        }
        let excluded = Set(person.links.map(\.accountKey))
        let grouped = Dictionary(grouping: evidence, by: \.accountID)
        return accounts.compactMap { account -> Lead? in
            guard !excluded.contains(account.id), [.candidate, .manual].contains(account.finding.status) else { return nil }
            let overlaps = (grouped[account.id] ?? []).compactMap { item -> Overlap? in
                guard let reference = references[item.identifier] else { return nil }
                return Overlap(evidence: item, referenceURL: reference.0, referenceDate: reference.1)
            }.sorted {
                ($0.evidence.identifier, $0.evidence.source.absoluteString, $0.evidence.observedAt, $0.id.uuidString)
                    < ($1.evidence.identifier, $1.evidence.source.absoluteString, $1.evidence.observedAt, $1.id.uuidString)
            }
            return overlaps.isEmpty ? nil : Lead(account: account, overlaps: overlaps)
        }.sorted {
            $0.identifierCount == $1.identifierCount ? $0.id < $1.id : $0.identifierCount > $1.identifierCount
        }
    }

    private func validAccount(_ name: String, _ finding: BeholderFinding) -> Bool {
        if finding.provider.isManual {
            return finding.status == .manual && finding.checkedAt == nil && finding.sourceURL == nil
                && finding.preparedProfileURL == finding.provider.profileURL(name)
        }
        return finding.status == .candidate && finding.checkedAt != nil && finding.sourceURL == finding.provider.endpoint(name)
    }
}
