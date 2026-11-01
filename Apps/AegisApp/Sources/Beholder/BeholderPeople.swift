import Foundation

/// Owner-authored research hypotheses. Linking never changes source findings or asserts a verified identity.
struct BeholderPeople: Codable, Equatable, Sendable {
    enum Assessment: String, Codable, CaseIterable, Sendable, Identifiable {
        case possible, supported, ruledOut = "ruled_out"
        var title: String {
            switch self {
            case .possible: "Possible"
            case .supported: "Supported by you"
            case .ruledOut: "Ruled out"
            }
        }

        var id: String {
            rawValue
        }
    }

    struct Person: Codable, Equatable, Sendable, Identifiable {
        let id: UUID
        let name: String
        var links: [AccountLink] = []
    }

    struct AccountLink: Codable, Equatable, Sendable, Identifiable {
        let id: UUID
        let username: String
        /// Immutable original observation, separate from the owner's later assessment.
        let finding: BeholderFinding
        var assessment: Assessment
        var reason: String
        var evidenceURL: URL?
        var assessedAt: Date
        var lastObservedAt: Date?

        var accountKey: String {
            // Manual paths retain exact spelling; only known API semantics normalise case/namespaces.
            finding.provider.rawValue + ":" + (finding.provider.isManual ? username : finding.provider.lookupHandle(username))
        }

        /// Conservative conflict detection only; never combines differently spelled manual records.
        var supportKey: String {
            finding.provider.isManual ? finding.provider.rawValue + ":" + username.lowercased() : accountKey
        }
    }

    enum Problem: Error {
        case label, reason, source, evidence, conflict, capacity, missing
        var message: String {
            switch self {
            case .label: "Use a person label of 1–80 characters, without hidden controls."
            case .reason: "Use a one-line explanation of 6–1,000 characters, without hidden controls."
            case .source: "Only a returned candidate or a prepared manual profile can be linked."
            case .evidence: "Evidence must be a public HTTPS URL without credentials. Supported links require an evidence URL."
            case .conflict: "This account or a case variant is already supported under another person. Reassess that link first."
            case .capacity: "This case is full. Export it before starting another case."
            case .missing: "Select a person in this case first."
            }
        }
    }

    private(set) var people: [Person] = []

    /// Restores validated records, preserving UUIDs and immutable original observations.
    static func restoring(_ records: [Person]) throws -> Self {
        try BeholderCaseFile.validatePeople(records)
        var restored = Self()
        restored.people = records
        return restored
    }

    @discardableResult mutating func create(_ name: String) throws -> UUID {
        guard let label = Self.text(name, range: 1 ... 80) else { throw Problem.label }
        guard people.count < 50 else { throw Problem.capacity }
        let person = Person(id: UUID(), name: label)
        people.append(person)
        return person.id
    }

    mutating func link(
        personID: UUID, username: String, finding: BeholderFinding, assessment: Assessment,
        reason: String, evidence: String, now: Date = Date()
    ) throws {
        guard let person = people.firstIndex(where: { $0.id == personID }) else { throw Problem.missing }
        guard let explanation = Self.text(reason, range: 6 ... 1000) else { throw Problem.reason }
        let provider = finding.provider
        guard BeholderProvider.username(username) == username, provider.supports(username),
              (finding.status == .candidate && finding.checkedAt != nil && finding.sourceURL == provider.endpoint(username)
                  && !provider.isManual)
              || (finding.status == .manual && provider.isManual && finding.checkedAt == nil && finding.sourceURL == nil
                  && finding.preparedProfileURL == provider.profileURL(username)) else { throw Problem.source }
        guard Self.safe(evidence) else { throw Problem.evidence }
        let input = evidence.trimmingCharacters(in: .whitespaces)
        let url = input.isEmpty ? nil : Self.evidenceURL(input)
        guard input.isEmpty || url != nil, assessment != .supported || url != nil else { throw Problem.evidence }
        var link = AccountLink(
            id: UUID(), username: username, finding: finding, assessment: assessment,
            reason: explanation, evidenceURL: url, assessedAt: now, lastObservedAt: finding.checkedAt
        )
        if assessment == .supported, people.contains(where: {
            $0.id != personID && $0.links.contains { $0.supportKey == link.supportKey && $0.assessment == .supported }
        }) {
            throw Problem.conflict
        }
        if let existing = people[person].links.firstIndex(where: { $0.accountKey == link.accountKey }) {
            // Retain the original source snapshot and stable row ID when reassessing a link.
            link = people[person].links[existing]
            link.assessment = assessment; link.reason = explanation; link.evidenceURL = url; link.assessedAt = now
            if let checked = finding.checkedAt, checked > (link.lastObservedAt ?? .distantPast) {
                link.lastObservedAt = checked
            }
            people[person].links[existing] = link
        } else {
            guard people[person].links.count < 100 else { throw Problem.capacity }
            people[person].links.append(link)
        }
    }

    /// An edit is pinned to an existing row and cannot create a link under another person.
    mutating func reassess(personID: UUID, linkID: UUID, assessment: Assessment, reason: String, evidence: String) throws {
        guard let existing = people.first(where: { $0.id == personID })?.links.first(where: { $0.id == linkID }) else {
            throw Problem.missing
        }
        try link(
            personID: personID,
            username: existing.username,
            finding: existing.finding,
            assessment: assessment,
            reason: reason,
            evidence: evidence
        )
    }

    mutating func remove(personID: UUID, linkID: UUID) {
        guard let person = people.firstIndex(where: { $0.id == personID }) else { return }
        people[person].links.removeAll { $0.id == linkID }
    }

    private static func text(_ input: String, range: ClosedRange<Int>) -> String? {
        guard input.utf8.count <= range.upperBound * 4, safe(input) else { return nil }
        let value = input.trimmingCharacters(in: .whitespaces)
        return range.contains(value.unicodeScalars.count) ? value : nil
    }

    private static func safe(_ input: String) -> Bool {
        input.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                && $0.properties.generalCategory != .format
        }
    }

    static func evidenceURL(_ input: String) -> URL? {
        guard BeholderProfileLinks.canonical(input) != nil, input.utf8.count <= 2048, safe(input), !input.contains(" "),
              let parts = URLComponents(string: input), parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, let host = parts.host, BeholderQueryPlanner.domain(host) != nil,
              !["local", "localhost", "internal", "invalid", "test", "onion", "lan", "home", "localdomain"]
              .contains(host.lowercased().split(separator: ".").last.map(String.init) ?? "")
        else { return nil }
        return parts.url
    }
}
