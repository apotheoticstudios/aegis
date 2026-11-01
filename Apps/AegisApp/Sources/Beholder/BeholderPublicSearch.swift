import Foundation

/// Browser-assisted searches for the owner's explicitly typed seed only. No case, memory or transport access.
enum BeholderPublicSearch {
    enum Service: String, CaseIterable, Identifiable {
        case duckDuckGo = "DuckDuckGo web search", github = "GitHub users"
        var id: String {
            rawValue
        }

        // privacy-guard: allow-network ADR-0036 fixed destinations for explicit browser searches only
        var host: String {
            self == .github ? "github.com" : "duckduckgo.com"
        }

        func supports(_ kind: BeholderCaseSearch.Kind) -> Bool {
            switch kind {
            case .username, .name, .email: true
            case .phone: self == .duckDuckGo
            case .ip: false
            }
        }
    }

    struct Input: Equatable {
        let value: String
        let kind: BeholderCaseSearch.Kind
        let region: BeholderQueryPlanner.PhoneRegion
    }

    /// A source choice authorizes only the exact input present when it was chosen.
    struct Selection {
        let service: Service
        let input: Input
        func plan(for current: Input) -> Plan? {
            current == input ? BeholderPublicSearch.prepare(current, service: service) : nil
        }
    }

    struct Plan {
        let query: String
        let destination: URL
        let host: String
    }

    /// Primary references: DuckDuckGo help/settings/params and GitHub docs/searching-users (ADR-0036).
    static func prepare(_ input: Input, service: Service) -> Plan? {
        guard service.supports(input.kind) else { return nil }
        let seed: String
        switch input.kind {
        case .username:
            guard let value = BeholderCaseSearch.username(input.value) else { return nil }; seed = value
        case .name:
            guard case let .success(plan) = BeholderQueryPlanner.build(input: input.value, kind: .name)
            else { return nil }; seed = plan.seed
        case .email, .phone:
            guard let value = BeholderIdentifier(input: input.value, kind: input.kind == .email ? .email : .phone, region: input.region)
            else { return nil }; seed = value.value
        case .ip: return nil // IP context remains offline; it cannot identify a subscriber or email.
        }
        var query = "\"" + seed + "\""
        if service == .github {
            switch input.kind {
            case .username: query += " in:login"
            case .name: query += " in:name"
            case .email: query += " in:email"
            default: return nil
            }
        }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = service.host
        parts.path = service == .github ? "/search" : "/"
        parts.queryItems = (service == .github ? [URLQueryItem(name: "type", value: "users")] : [])
            + [URLQueryItem(name: "q", value: query)]
        // Browser search endpoints use form decoding; a literal '+' must survive as a plus, not a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url, url.absoluteString.utf8.count <= 2048 else { return nil }
        return Plan(query: query, destination: url, host: service.host)
    }
}
