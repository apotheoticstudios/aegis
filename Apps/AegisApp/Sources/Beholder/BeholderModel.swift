import Foundation
import Observation

@MainActor @Observable
final class BeholderModel {
    var query = ""
    var selected = BeholderProvider.originalSources
    var people = BeholderPeople() {
        didSet { caseRevision &+= 1 }
    }

    var correlation = BeholderCorrelation() {
        didSet { caseRevision &+= 1 }
    }

    private(set) var caseRevision: UInt64 = 0
    static let parallelLimit = 4
    private(set) var username = ""
    private(set) var findings: [BeholderFinding] = []
    private(set) var searching = false
    private(set) var problem: String?
    private(set) var importProvenance: BeholderCaseFile.ImportProvenance?
    var includesImportedObservations: Bool {
        importProvenance != nil
    }

    var importDescription: String? {
        importProvenance.map { "Imported \($0.importedAt.formatted()); original source exported \($0.sourceExportedAt.formatted())." }
    }

    private var generation = UUID()
    /// A case/session boundary; ordinary username lookups keep the same research context.
    private(set) var discoveryContextID = UUID()
    private var job: Task<Void, Never>?
    private let client: any BeholderSearching
    let githubDiscovery: BeholderGitHubResearch
    let unifiedSearch: BeholderUnifiedSearch

    init(
        client: any BeholderSearching = BeholderClient(),
        discoveryClient: any BeholderGitHubDiscovering = BeholderGitHubDiscoveryClient()
    ) {
        self.client = client
        githubDiscovery = BeholderGitHubResearch(client: discoveryClient)
        unifiedSearch = BeholderUnifiedSearch(github: githubDiscovery)
        unifiedSearch.edited = { [weak self] in self?.stopLookup() }
    }

    var candidates: Int {
        findings.filter { $0.status == .candidate }.count
    }

    var hasCase: Bool {
        !findings.isEmpty || !people.people.isEmpty || !correlation.accounts.isEmpty || !correlation.hints.isEmpty
    }

    var preparedUsername: String? {
        BeholderCaseSearch.username(query)
    }

    /// Also changes when the standalone window closes, so view-owned reads cancel with lookups.
    var cancellationID: UUID {
        generation
    }

    var providers: [BeholderProvider] {
        BeholderProvider.allCases.filter { selected.contains($0) }
    }

    func start(providers requested: [BeholderProvider]? = nil) {
        let chosen = requested ?? providers
        guard let name = preparedUsername, !chosen.isEmpty else {
            problem = BeholderCaseSearch.usernameProblem(query) ??
                "Enter one username using letters, numbers, dots, dashes or underscores, and choose at least one source."
            return
        }
        stopLookup()
        let token = UUID()
        generation = token
        username = name
        problem = nil
        findings = chosen.map { $0.manualFinding(name) ?? BeholderFinding(provider: $0, status: .queued, sourceURL: $0.endpoint(name)) }
        for finding in findings {
            archive(finding)
        }
        let sources = chosen.filter { !$0.isManual }
        searching = !sources.isEmpty
        guard searching else { return }
        let client = client
        job = Task { [weak self] in
            await withTaskGroup(of: BeholderFinding.self) { group in
                var remaining = sources.makeIterator()
                for _ in 0 ..< Self.parallelLimit {
                    guard let provider = remaining.next() else { break }
                    guard !Task.isCancelled, self?.markStarted(provider, generation: token) == true else { group.cancelAll(); break }
                    group.addTaskUnlessCancelled { await client.lookup(provider, username: name) }
                }
                for await finding in group {
                    if Task.isCancelled || self?.accept(finding, generation: token) != true {
                        group.cancelAll()
                        continue
                    }
                    if let provider = remaining.next(), !Task.isCancelled, self?.markStarted(provider, generation: token) == true {
                        group.addTaskUnlessCancelled { await client.lookup(provider, username: name) }
                    }
                }
            }
            self?.finish(generation: token)
        }
    }

    private func markStarted(_ provider: BeholderProvider, generation token: UUID) -> Bool {
        guard generation == token, let index = findings.firstIndex(where: { $0.provider == provider }) else { return false }
        findings[index].status = .checking
        return true
    }

    private func accept(_ finding: BeholderFinding, generation token: UUID) -> Bool {
        guard generation == token else { return false }
        if let offset = findings.firstIndex(where: { $0.provider == finding.provider }) {
            findings[offset] = finding
            archive(finding)
        }
        return true
    }

    private func finish(generation token: UUID) {
        guard generation == token else { return }
        searching = false
        job = nil
    }

    func cancel() {
        unifiedSearch.stopPublicWork()
        discoveryContextID = UUID()
        stopLookup()
    }

    /// Stop only the username lookup, keeping the owner's separate Discover work intact.
    func stopLookup() {
        generation = UUID()
        job?.cancel()
        job = nil
        searching = false
        for index in findings.indices where [.checking, .queued].contains(findings[index].status) {
            findings[index].status = .cancelled
            archive(findings[index])
        }
    }

    func clear() {
        cancel()
        unifiedSearch.reset()
        query = ""
        username = ""
        findings = []
        people = BeholderPeople()
        correlation = BeholderCorrelation()
        importProvenance = nil
        problem = nil
    }

    /// An explicit review shortcut. Existing assessments, including manual case variants, are never replaced.
    @discardableResult func savePossible(personID: UUID, username: String, finding: BeholderFinding) throws -> Bool {
        guard let person = people.people.first(where: { $0.id == personID }) else { throw BeholderPeople.Problem.missing }
        let key = BeholderCorrelation.key(finding.provider, username)
        let supportKey = BeholderPeople.supportKey(provider: finding.provider, username: username)
        guard !person.links.contains(where: { $0.accountKey == key || $0.supportKey == supportKey }) else { return false }
        guard !people.people.contains(where: {
            $0.id != personID && $0.links.contains { $0.supportKey == supportKey && $0.assessment == .supported }
        }) else { throw BeholderPeople.Problem.conflict }
        try people.link(
            personID: personID,
            username: username,
            finding: finding,
            assessment: .possible,
            reason: "Saved as possible from results; identity has not been reviewed.",
            evidence: ""
        )
        return true
    }

    func export() throws -> Data {
        try BeholderCaseFile.encode(
            username: username,
            findings: findings,
            people: people,
            correlation: correlation,
            importedFrom: importProvenance
        )
    }

    /// Only a validated exact public GitHub profile may reach the case; search queries/hits never do.
    func recordGitHubInspection(login: String, finding: BeholderFinding) -> Bool {
        guard BeholderGitHubDiscovery.validLogin(login), finding.provider == .github,
              finding.sourceURL == BeholderProvider.github.endpoint(login), finding.checkedAt != nil,
              [.candidate, .noResult, .limited, .unavailable].contains(finding.status) else { return false }
        guard BeholderCaseFile.acceptsFinding(finding, username: login) else { return false }
        if finding.status == .candidate {
            guard finding.fields["Account type"] == "User",
                  finding.fields["Handle"]?.lowercased() == login.lowercased() else { return false }
        }
        let result = correlation.observe(username: login, finding: finding)
        if result == .capacity {
            problem = "This case has reached its account limit. Export it before starting another."; return false
        }
        return result == .recorded || finding.status != .candidate
    }

    /// Validate the entire immutable input before cancelling work or replacing any active case value.
    func importCase(_ data: Data) throws {
        let snapshot = try BeholderCaseFile.decode(data)
        cancel()
        unifiedSearch.reset()
        query = snapshot.username
        username = snapshot.username
        findings = snapshot.findings
        people = snapshot.people
        correlation = snapshot.correlation
        let sourceDate = min(snapshot.importedFrom?.sourceExportedAt ?? snapshot.exportedAt, snapshot.exportedAt)
        importProvenance = .init(importedAt: snapshot.importedAt, sourceExportedAt: sourceDate)
        problem = nil
    }

    private func archive(_ finding: BeholderFinding) {
        if correlation.observe(username: username, finding: finding) == .capacity {
            problem = "This case has reached its account limit. Export it before starting another."
        }
    }
}
