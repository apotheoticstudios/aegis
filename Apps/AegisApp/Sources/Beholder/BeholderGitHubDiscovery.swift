import CoreFoundation
import Foundation
import Observation

/// Only explicit, transient input reaches this builder. No case or model dependency.
enum BeholderGitHubDiscovery {
    enum Kind: String, CaseIterable, Sendable { case name = "Name", email = "Email" }
    struct Input: Equatable, Sendable { let value: String; let kind: Kind }
    struct Request: Equatable, Sendable { let input: Input; let seed: String; let query: String; let endpoint: URL }
    struct Hit: Equatable, Identifiable, Sendable {
        let login: String
        var id: String {
            login.lowercased()
        }
    }

    struct Page: Equatable, Sendable {
        let request: Request
        let hits: [Hit]
        let total: Int
        let incomplete: Bool
        let checkedAt: Date
    }

    enum Problem: Error, Equatable, Sendable {
        case input, unavailable, limited, response, context, profile
        var message: String {
            switch self {
            case .input: "Enter a complete name or email and press Search."
            case .unavailable: "GitHub could not be reached. No search result was established."
            case .limited: "GitHub refused or rate-limited this request. Try again later; nothing retries automatically."
            case .response: "GitHub's response could not be validated. This is not evidence that no accounts exist."
            case .context: "This research session changed. Inspect the result again in the current case."
            case .profile: "The profile could not be validated or added to this case."
            }
        }
    }

    enum EmailComparison: String {
        case notRequested = "A name search is not an identity match."
        case unavailable = "No public profile email was returned; that proves nothing about ownership."
        case exact = "The public email matches this query exactly; ownership still needs review."
        case caseVariant = "The public email differs in local-part case; verify manually."
        case different = "The public email differs from the query. Search uses containment, not exact identity matching."
    }

    static func prepare(_ input: Input) -> Request? {
        let seed: String
        switch input.kind {
        case .name:
            guard case let .success(plan) = BeholderQueryPlanner.build(input: input.value, kind: .name) else { return nil }
            seed = plan.seed
        case .email:
            guard let value = BeholderIdentifier(input: input.value, kind: .email) else { return nil }; seed = value.value
        }
        let query = "\"" + seed + "\" in:" + (input.kind == .name ? "name" : "email") + " type:user"
        // privacy-guard: allow-network ADR-0037, #144; exact owner-prepared public GitHub search only
        var parts = URLComponents(); parts.scheme = "https"; parts.host = "api.github.com"; parts.path = "/search/users"
        parts.queryItems = [.init(name: "q", value: query), .init(name: "per_page", value: "20"), .init(name: "page", value: "1")]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let endpoint = parts.url, endpoint.absoluteString.utf8.count <= 2048 else { return nil }
        return Request(input: input, seed: seed, query: query, endpoint: endpoint)
    }

    /// Exact rebuild, including query order/encoding. Not an arbitrary URL or query allow-list.
    static func permits(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = parts.queryItems?.first(where: { $0.name == "q" })?.value else { return false }
        for kind in Kind.allCases {
            let suffix = "\" in:" + (kind == .name ? "name" : "email") + " type:user"
            guard query.hasPrefix("\""), query.hasSuffix(suffix) else { continue }
            let seed = String(query.dropFirst().dropLast(suffix.count))
            if prepare(.init(value: seed, kind: kind))?.endpoint.absoluteString == url.absoluteString {
                return true
            }
        }
        return false
    }

    static func validLogin(_ value: String) -> Bool {
        BeholderProvider.username(value) == value && BeholderProvider.github.supports(value)
    }

    static func parse(_ payload: BeholderPayload, request: Request, now: Date) -> Result<Page, Problem> {
        if payload.rateLimited || [403, 429].contains(payload.status) {
            return .failure(.limited)
        }
        guard payload.status == 200 else { return .failure(.unavailable) }
        guard payload.data.count <= BeholderWebTransport.byteLimit,
              let root = (try? JSONSerialization.jsonObject(with: payload.data)) as? [String: Any],
              let total = root["total_count"] as? NSNumber, CFGetTypeID(total) != CFBooleanGetTypeID(),
              total.doubleValue >= 0, total.doubleValue <= 1_000_000_000, total.doubleValue.rounded() == total.doubleValue,
              let incomplete = root["incomplete_results"] as? NSNumber, CFGetTypeID(incomplete) == CFBooleanGetTypeID(),
              let items = root["items"] as? [[String: Any]] else { return .failure(.response) }
        var hits: [Hit] = [], seen = Set<String>()
        for item in items.prefix(20) {
            guard item["type"] as? String == "User", let login = item["login"] as? String, validLogin(login) else {
                return .failure(.response)
            }
            if seen.insert(login.lowercased()).inserted {
                hits.append(.init(login: login))
            }
        }
        guard total.intValue >= hits.count else { return .failure(.response) }
        return .success(Page(
            request: request,
            hits: hits,
            total: total.intValue,
            incomplete: incomplete.boolValue,
            checkedAt: now
        ))
    }

    static func compareEmail(_ finding: BeholderFinding, request: Request) -> EmailComparison {
        guard request.input.kind == .email else { return .notRequested }
        guard finding.status == .candidate else { return .unavailable }
        guard let raw = finding.fields["Public email"], let published = BeholderIdentifier(input: raw, kind: .email),
              let sought = BeholderIdentifier(input: request.seed, kind: .email) else { return .unavailable }
        if published == sought {
            return .exact
        }
        return published.value.lowercased() == sought.value.lowercased() ? .caseVariant : .different
    }
}

protocol BeholderGitHubDiscovering: Sendable {
    func search(_ request: BeholderGitHubDiscovery.Request) async -> Result<BeholderGitHubDiscovery.Page, BeholderGitHubDiscovery.Problem>
    func inspect(_ login: String) async -> BeholderFinding
}

struct BeholderGitHubDiscoveryClient: BeholderGitHubDiscovering {
    var transport: any BeholderTransport = BeholderWebTransport(permitsGitHubDiscovery: true)
    func search(_ request: BeholderGitHubDiscovery.Request) async -> Result<BeholderGitHubDiscovery.Page, BeholderGitHubDiscovery.Problem> {
        guard BeholderGitHubDiscovery.prepare(request.input) == request else { return .failure(.input) }
        do {
            try Task.checkCancellation()
            let payload = try await transport.get(request.endpoint, accept: "application/vnd.github+json")
            try Task.checkCancellation()
            return BeholderGitHubDiscovery.parse(payload, request: request, now: Date())
        } catch { return .failure(.unavailable) }
    }

    func inspect(_ login: String) async -> BeholderFinding {
        guard BeholderGitHubDiscovery.validLogin(login) else { return BeholderFinding(provider: .github, status: .unsupported) }
        // privacy-guard: allow-network ADR-0037/0039, #159; owner-started research reuses the fixed GitHub profile adapter
        return await BeholderClient(transport: transport).lookup(.github, username: login)
    }
}

/// Input edits invalidate choices and completions immediately, before UI onChange callbacks.
@MainActor @Observable
final class BeholderGitHubResearch {
    var value = "" {
        didSet { invalidate() }
    }

    var kind = BeholderGitHubDiscovery.Kind.name {
        didSet {
            if oldValue != kind {
                value = ""
            }
        }
    }

    private(set) var prepared: BeholderGitHubDiscovery.Request?
    private(set) var page: BeholderGitHubDiscovery.Page?
    private(set) var inspected: BeholderFinding?
    private(set) var inspectedLogin: String?
    private(set) var problem: BeholderGitHubDiscovery.Problem?
    private(set) var searching = false
    private(set) var inspecting: String?
    private(set) var automatic = false
    private(set) var profiles: [String: BeholderFinding] = [:]
    private(set) var rejectedProfiles = Set<String>()
    private var generation = UUID()
    private var job: Task<Void, Never>?
    private let client: any BeholderGitHubDiscovering

    init(client: any BeholderGitHubDiscovering = BeholderGitHubDiscoveryClient()) {
        self.client = client
    }

    var input: BeholderGitHubDiscovery.Input {
        .init(value: value, kind: kind)
    }

    var canPrepare: Bool {
        BeholderGitHubDiscovery.prepare(input) != nil
    }

    /// Display groups preserve the search provider's order; they never infer identity or start requests.
    var foundHits: [BeholderGitHubDiscovery.Hit] {
        (page?.hits ?? []).filter { profiles[$0.login]?.status == .candidate }
    }

    var pendingHits: [BeholderGitHubDiscovery.Hit] {
        (page?.hits ?? []).filter { profiles[$0.login] == nil && !rejectedProfiles.contains($0.login) }
    }

    var otherHits: [BeholderGitHubDiscovery.Hit] {
        (page?.hits ?? []).filter { rejectedProfiles.contains($0.login) || profiles[$0.login].map { $0.status != .candidate } == true }
    }

    var checkedCount: Int {
        profiles.count + rejectedProfiles.count
    }

    var unresolvedCount: Int {
        rejectedProfiles.count + profiles.values.filter { [.limited, .unavailable].contains($0.status) }.count
    }

    func invalidate() {
        generation = UUID(); job?.cancel(); job = nil
        prepared = nil; page = nil; inspected = nil; inspectedLogin = nil
        problem = nil; searching = false; inspecting = nil
        automatic = false; profiles.removeAll(); rejectedProfiles.removeAll()
    }

    func reset() {
        value = ""; kind = .name; invalidate()
    }

    /// Cancel the current request without discarding a page already returned by an explicit Search.
    func stop() {
        generation = UUID(); job?.cancel(); job = nil
        searching = false; inspecting = nil; inspected = nil; inspectedLogin = nil; problem = nil
    }

    func chooseGitHub() {
        invalidate(); prepared = BeholderGitHubDiscovery.prepare(input)
        if prepared == nil {
            problem = .input
        }
    }

    func search(into model: BeholderModel? = nil) {
        guard let request = prepared, request.input == input else { return }
        invalidate(); prepared = request; searching = true; automatic = model != nil
        let token = generation, client = client, context = model?.discoveryContextID
        job = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result = await client.search(request)
            guard let self, generation == token, !Task.isCancelled else { return }
            switch result {
            case let .success(page) where page.request == request && page.hits.count <= 20 &&
                page.hits.allSatisfy { BeholderGitHubDiscovery.validLogin($0.login) } && Set(page.hits.map(\.id)).count == page.hits.count:
                self.page = page
                if let model, let context {
                    await fetchProfiles(page, token: token, context: context, into: model)
                }
            case .success: problem = .response
            case let .failure(problem): self.problem = problem
            }
            guard generation == token else { return }
            searching = false; job = nil
        }
    }

    private func fetchProfiles(_ page: BeholderGitHubDiscovery.Page, token: UUID, context: UUID, into model: BeholderModel) async {
        guard model.discoveryContextID == context else { problem = .context; return }
        let client = client
        await withTaskGroup(of: (String, BeholderFinding).self) { group in
            var remaining = page.hits.makeIterator()
            var limited = false
            for _ in 0 ..< BeholderModel.parallelLimit {
                guard !Task.isCancelled, generation == token, model.discoveryContextID == context,
                      let hit = remaining.next() else { break }
                group.addTask { await (hit.login, client.inspect(hit.login)) }
            }
            for await (login, finding) in group {
                guard !limited, !Task.isCancelled, generation == token else { group.cancelAll(); continue }
                guard model.discoveryContextID == context else { problem = .context; group.cancelAll(); continue }
                if model.recordGitHubInspection(login: login, finding: finding) {
                    profiles[login] = finding
                } else {
                    rejectedProfiles.insert(login)
                    problem = .profile
                }
                if finding.status == .limited {
                    limited = true; problem = .limited; group.cancelAll()
                }
                if !limited, let hit = remaining.next(), !Task.isCancelled {
                    group.addTask { await (hit.login, client.inspect(hit.login)) }
                }
            }
        }
    }

    func inspect(_ hit: BeholderGitHubDiscovery.Hit, into model: BeholderModel) {
        guard !automatic, let page, page.request == prepared, page.hits.contains(hit),
              BeholderGitHubDiscovery.validLogin(hit.login) else { return }
        job?.cancel(); generation = UUID(); searching = false; inspecting = hit.login
        inspected = nil; inspectedLogin = nil; problem = nil
        let token = generation, caseToken = model.discoveryContextID, client = client
        job = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let finding = await client.inspect(hit.login)
            guard let self, generation == token, !Task.isCancelled else { return }
            inspecting = nil; job = nil
            guard model.discoveryContextID == caseToken else { problem = .context; return }
            guard model.recordGitHubInspection(login: hit.login, finding: finding) else { problem = .profile; return }
            inspected = finding; inspectedLogin = hit.login
        }
    }
}
