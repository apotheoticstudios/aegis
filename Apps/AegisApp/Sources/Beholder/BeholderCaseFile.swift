import Foundation

/// An inert, bounded case document. Decoding never verifies claims, opens URLs or reads other files.
enum BeholderCaseFile {
    static let byteLimit = 8 * 1024 * 1024
    static let provenanceNote = "Imported observations, statuses and check times are claims in a file, "
        + "not independently verified by Beholder. "
        + "Contains locally recorded phone/email identifiers. Candidate accounts are not verified identities. Prepared manual links are unchecked."

    struct ImportProvenance: Codable, Equatable, Sendable {
        let importedAt: Date
        let sourceExportedAt: Date
    }

    struct Snapshot: Equatable, Sendable {
        let schema: Int
        let username: String
        let exportedAt: Date
        let findings: [BeholderFinding]
        let people: BeholderPeople
        let correlation: BeholderCorrelation
        let importedAt: Date
        let importedFrom: ImportProvenance?
        var provenanceNote: String {
            BeholderCaseFile.provenanceNote
        }
    }

    enum Problem: Error, Equatable {
        case malformed, version, capacity, username, finding, people, evidence, reference, date
        var message: String {
            switch self {
            case .version: "This case uses an unsupported file version."
            case .capacity: "This case exceeds the file, text or record limits."
            default: "This case contains invalid or conflicting records. The current case has not been changed."
            }
        }
    }

    private struct Report: Codable {
        let schema: Int
        let username: String
        let exportedAt: Date
        var warning: String?
        let findings: [BeholderFinding]
        let people: [BeholderPeople.Person]
        let correlation: BeholderCorrelation?
        let importedFrom: ImportProvenance?
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> Snapshot {
        guard data.count <= byteLimit else { throw Problem.capacity }
        do {
            try preflight(data)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let report = try decoder.decode(Report.self, from: data)
            guard (report.username.isEmpty && report.findings.isEmpty)
                || BeholderProvider.username(report.username) == report.username else { throw Problem.username }
            try validDate(report.exportedAt)
            try validDate(now)
            if let origin = report.importedFrom {
                try validDate(origin.importedAt)
                try validDate(origin.sourceExportedAt)
            }
            guard Set(report.findings.map(\.provider)).count == report.findings.count else { throw Problem.finding }
            for finding in report.findings {
                try validateFinding(finding, username: report.username)
            }
            let people = try BeholderPeople.restoring(report.people)
            let correlation = report.correlation ?? BeholderCorrelation()
            try validateCorrelation(correlation, people: people)
            let accounts = Dictionary(uniqueKeysWithValues: correlation.accounts.map { ($0.id, $0) })
            for finding in report.findings {
                if let account = accounts[BeholderCorrelation.key(finding.provider, report.username)] {
                    let latest = account.latestAttempt?.finding ?? account.finding
                    guard latest == finding else { throw Problem.finding }
                }
            }
            return Snapshot(
                schema: report.schema, username: report.username, exportedAt: report.exportedAt,
                findings: report.findings, people: people, correlation: correlation, importedAt: now, importedFrom: report.importedFrom
            )
        } catch let error as Problem {
            throw error
        } catch {
            throw Problem.malformed
        }
    }

    static func encode(
        username: String, findings: [BeholderFinding], people: BeholderPeople,
        correlation: BeholderCorrelation, exportedAt: Date = Date(), importedFrom: ImportProvenance? = nil
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Report(
            schema: 4, username: username, exportedAt: exportedAt, warning: provenanceNote,
            findings: findings, people: people.people, correlation: correlation, importedFrom: importedFrom
        ))
        _ = try decode(data)
        return data
    }

    /// Used by the restoration entry point so callers cannot bypass the people invariants.
    static func validatePeople(_ people: [BeholderPeople.Person]) throws {
        guard people.count <= 50 else { throw Problem.capacity }
        var ids: Set<UUID> = []
        var supported: [String: UUID] = [:]
        for person in people {
            guard ids.insert(person.id).inserted else { throw Problem.people }
            try text(person.name, limit: 80, minimum: 1)
            guard person.links.count <= 100 else { throw Problem.capacity }
            var keys: Set<String> = []
            for link in person.links {
                guard ids.insert(link.id).inserted, keys.insert(link.accountKey).inserted,
                      [.candidate, .manual].contains(link.finding.status) else { throw Problem.people }
                try validateLink(link)
                if link.assessment == .supported {
                    guard link.evidenceURL != nil, supported[link.supportKey] == nil else { throw Problem.people }
                    supported[link.supportKey] = person.id
                }
            }
        }
    }
}

private extension BeholderCaseFile {
    static func validateLink(_ link: BeholderPeople.AccountLink) throws {
        try validateFinding(link.finding, username: link.username)
        try text(link.reason, limit: 1000, minimum: 6)
        try validDate(link.assessedAt)
        if let last = link.lastObservedAt {
            try validDate(last)
            guard last >= (link.finding.checkedAt ?? last) else { throw Problem.date }
        }
        if let url = link.evidenceURL {
            try evidenceURL(url)
        }
    }

    static func validateFinding(_ finding: BeholderFinding, username: String) throws {
        guard BeholderProvider.username(username) == username else { throw Problem.username }
        guard finding.fields.count <= 32 else { throw Problem.capacity }
        for (key, value) in finding.fields {
            try text(key, limit: 80, minimum: 1)
            try text(value, limit: 1000)
        }
        if let date = finding.checkedAt {
            try validDate(date)
        }
        let provider = finding.provider
        var labels: Set<String> = provider.isManual ? ["Access"] : [
            "Handle",
            "Display name",
            "Bio",
            "About",
            "Account type",
            "Account state",
        ]
        if provider == .github {
            labels.insert("Public email")
        }
        if provider == .writeAs {
            labels.insert("Profile type")
        }
        if provider == .scratch {
            labels.insert("Working on")
        }
        guard Set(finding.fields.keys).isSubset(of: labels) else { throw Problem.finding }
        if let access = finding.fields["Access"], access != provider.manualFinding(username)?.fields["Access"] {
            throw Problem.finding
        }
        if provider.isManual {
            try validateManual(finding, username: username)
        } else {
            try validateAutomatic(finding, username: username)
        }
        if let handle = finding.fields["Handle"] {
            guard finding.status == .candidate,
                  provider == .hackerNews ? handle == username : handle.lowercased() == provider.lookupHandle(username)
            else { throw Problem.finding }
        }
    }

    static func validateManual(_ finding: BeholderFinding, username: String) throws {
        let provider = finding.provider
        guard finding.access != .automatic, finding.checkedAt == nil, finding.sourceURL == nil,
              (finding.status == .manual && provider.supports(username)
                  && finding.preparedProfileURL == provider.profileURL(username))
              || (finding.status == .unsupported && !provider.supports(username) && finding.preparedProfileURL == nil)
        else { throw Problem.finding }
    }

    static func validateAutomatic(_ finding: BeholderFinding, username: String) throws {
        let provider = finding.provider
        guard finding.access != .manual, finding.status != .manual, finding.preparedProfileURL == nil,
              finding.sourceURL == provider.endpoint(username) else { throw Problem.finding }
        switch finding.status {
        case .candidate, .noResult, .limited, .unavailable:
            guard provider.supports(username), finding.checkedAt != nil else { throw Problem.finding }
        case .queued, .checking:
            guard finding.checkedAt == nil else { throw Problem.finding }
        case .unsupported:
            guard !provider.supports(username), finding.checkedAt == nil else { throw Problem.finding }
        case .cancelled: break
        case .manual: throw Problem.finding
        }
    }

    static func validateCorrelation(_ store: BeholderCorrelation, people: BeholderPeople) throws {
        guard store.accounts.count <= 500, store.evidence.count <= 2000, store.hints.count <= 500 else { throw Problem.capacity }
        var accounts: [String: BeholderCorrelation.Account] = [:]
        for account in store.accounts {
            guard [.candidate, .manual, .noResult].contains(account.finding.status),
                  account.id == BeholderCorrelation.key(account.finding.provider, account.username), accounts[account.id] == nil
            else { throw Problem.reference }
            try validateFinding(account.finding, username: account.username)
            if let attempt = account.latestAttempt {
                guard BeholderCorrelation.key(attempt.finding.provider, attempt.username) == account.id,
                      [.queued, .checking, .cancelled, .limited, .unavailable].contains(attempt.finding.status)
                else { throw Problem.finding }
                try validateFinding(attempt.finding, username: attempt.username)
            }
            accounts[account.id] = account
        }
        let personIDs = Set(people.people.map(\.id))
        var ids = personIDs.union(people.people.flatMap { $0.links.map(\.id) })
        try validateEvidence(store.evidence, accounts: accounts, ids: &ids)
        try validateHints(store.hints, people: personIDs, ids: &ids)
    }

    static func validateEvidence(
        _ evidence: [BeholderCorrelation.Evidence], accounts: [String: BeholderCorrelation.Account], ids: inout Set<UUID>
    ) throws {
        var evidenceKeys: Set<String> = []
        for item in evidence {
            guard ids.insert(item.id).inserted, let account = accounts[item.accountID] else { throw Problem.reference }
            try evidenceURL(item.source)
            try validDate(item.observedAt)
            try identifier(item.identifier)
            let key = item.accountID + "\n" + item.identifier.kind.rawValue + "\n" + item.identifier.value
                + "\n" + item.source.absoluteString + "\n" + item.origin.rawValue
            guard evidenceKeys.insert(key).inserted else { throw Problem.evidence }
            if item.origin == .publicField {
                guard account.finding.provider == .github, account.finding.status == .candidate,
                      account.finding.sourceURL == item.source, account.finding.checkedAt == item.observedAt,
                      account.finding.fields["Public email"] == item.identifier.value, item.identifier.kind == .email
                else { throw Problem.evidence }
            }
        }
    }

    static func validateHints(_ hints: [BeholderCorrelation.Hint], people: Set<UUID>, ids: inout Set<UUID>) throws {
        var hintKeys: Set<String> = []
        for hint in hints {
            guard ids.insert(hint.id).inserted, people.contains(hint.personID) else { throw Problem.reference }
            try evidenceURL(hint.source)
            try validDate(hint.observedAt)
            try identifier(hint.identifier)
            let key = hint.personID.uuidString + "\n" + hint.identifier.kind.rawValue + "\n" + hint.identifier.value
                + "\n" + hint.source.absoluteString
            guard hintKeys.insert(key).inserted else { throw Problem.evidence }
        }
    }

    private static func identifier(_ item: BeholderIdentifier) throws {
        guard BeholderIdentifier(input: item.value, kind: item.kind) == item else { throw Problem.evidence }
    }

    private static func evidenceURL(_ url: URL) throws {
        guard BeholderPeople.evidenceURL(url.absoluteString) == url else { throw Problem.evidence }
    }

    private static func validDate(_ date: Date) throws {
        guard date.timeIntervalSince1970.isFinite, (0 ... 253_402_300_799).contains(date.timeIntervalSince1970)
        else { throw Problem.date }
    }

    private static func text(_ value: String, limit: Int, minimum: Int = 0) throws {
        guard value.utf8.count <= limit * 4, (minimum ... limit).contains(value.unicodeScalars.count)
        else { throw Problem.capacity }
        guard value == value.trimmingCharacters(in: .whitespaces), value.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                && !CharacterSet.illegalCharacters.contains($0) && $0.properties.generalCategory != .format
        }) else { throw Problem.malformed }
    }

    /// Inspect collection bounds and serialized keys before Codable can silently discard unknown or computed fields.
    private static func preflight(_ data: Data) throws {
        let root = try object(
            JSONSerialization.jsonObject(with: data),
            keys: "schema username exportedAt warning findings people correlation importedFrom"
        )
        if let value = root["importedFrom"], !(value is NSNull) {
            _ = try object(value, keys: "importedAt sourceExportedAt")
        }
        guard let schema = root["schema"] as? Int, [3, 4].contains(schema), !(root["schema"] is Bool) else { throw Problem.version }
        if let warning = root["warning"] as? String {
            try text(warning, limit: 2000)
        }
        for finding in try array(root["findings"], limit: BeholderProvider.allCases.count) {
            try findingShape(finding)
        }
        for value in try array(root["people"], limit: 50) {
            let person = try object(value, keys: "id name links")
            for value in try array(person["links"], limit: 100) {
                let link = try object(value, keys: "id username finding assessment reason evidenceURL assessedAt lastObservedAt")
                try findingShape(link["finding"])
            }
        }
        guard schema == 4 else {
            guard root["correlation"] == nil else { throw Problem.version }
            return
        }
        let store = try object(root["correlation"], keys: "accounts evidence hints")
        for value in try array(store["accounts"], limit: 500) {
            let account = try object(value, keys: "id username finding latestAttempt")
            try findingShape(account["finding"])
            if let value = account["latestAttempt"], !(value is NSNull) {
                let attempt = try object(value, keys: "username finding")
                try findingShape(attempt["finding"])
            }
        }
        for (name, keys, limit) in [
            ("evidence", "id accountID identifier source observedAt origin", 2000),
            ("hints", "id personID identifier source observedAt", 500),
        ] {
            for value in try array(store[name], limit: limit) {
                let item = try object(value, keys: keys)
                _ = try object(item["identifier"], keys: "kind value")
            }
        }
    }

    private static func findingShape(_ value: Any?) throws {
        let finding = try object(value, keys: "provider status checkedAt sourceURL preparedProfileURL access fields")
        guard let fields = finding["fields"] as? [String: String] else { throw Problem.malformed }
        guard fields.count <= 32 else { throw Problem.capacity }
    }

    private static func object(_ value: Any?, keys: String) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: Set(keys.split(separator: " ").map(String.init)))
        else { throw Problem.malformed }
        return object
    }

    private static func array(_ value: Any?, limit: Int) throws -> [Any] {
        guard let array = value as? [Any] else { throw Problem.malformed }
        guard array.count <= limit else { throw Problem.capacity }
        return array
    }
}
