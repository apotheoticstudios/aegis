import Foundation
import Observation

@MainActor @Observable
final class BeholderModel {
    var query = ""
    var selected = BeholderProvider.originalSources
    static let parallelLimit = 4
    private(set) var username = ""
    private(set) var findings: [BeholderFinding] = []
    private(set) var searching = false
    private(set) var problem: String?
    private var generation = UUID()
    private var job: Task<Void, Never>?
    private let client: any BeholderSearching

    init(client: any BeholderSearching = BeholderClient()) {
        self.client = client
    }

    var candidates: Int {
        findings.filter { $0.status == .candidate }.count
    }

    var preparedUsername: String? {
        BeholderProvider.username(query)
    }

    var providers: [BeholderProvider] {
        BeholderProvider.allCases.filter { selected.contains($0) }
    }

    func start() {
        guard let name = preparedUsername, !providers.isEmpty else {
            problem = "Enter one username using letters, numbers, dots, dashes or underscores, and choose at least one source."
            return
        }
        cancel()
        let token = UUID()
        generation = token
        username = name
        problem = nil
        let sources = providers
        findings = sources.map { BeholderFinding(provider: $0, status: .queued, sourceURL: $0.endpoint(name)) }
        searching = true
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
        }
        return true
    }

    private func finish(generation token: UUID) {
        guard generation == token else { return }
        searching = false
        job = nil
    }

    func cancel() {
        generation = UUID()
        job?.cancel()
        job = nil
        searching = false
        for index in findings.indices where [.checking, .queued].contains(findings[index].status) {
            findings[index].status = .cancelled
        }
    }

    func clear() {
        cancel()
        query = ""
        username = ""
        findings = []
        problem = nil
    }

    func export() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Report(schema: 1, username: username, exportedAt: Date(), findings: findings))
    }

    private struct Report: Encodable {
        let schema: Int
        let username: String
        let exportedAt: Date
        let warning = "Candidate accounts are not verified identities. No public result does not prove absence."
        let findings: [BeholderFinding]
    }
}
