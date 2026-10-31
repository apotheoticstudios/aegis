import Foundation

/// Local query construction only. A plan is neither a lookup nor evidence about a person.
enum BeholderQueryPlanner {
    enum Kind: String, CaseIterable, Identifiable {
        case username = "Username", name = "Name", email = "Email", phone = "Phone", domain = "Domain"
        var id: String {
            rawValue
        }
    }

    enum PhoneRegion: String, CaseIterable, Identifiable {
        case international = "International (+ required)", australia = "Australia (AU)"
        var id: String {
            rawValue
        }
    }

    enum DocumentKind: String, CaseIterable, Identifiable {
        case any = "Any format", pdf = "PDF", html = "HTML", text = "Plain text"
        var id: String {
            rawValue
        }

        var suffix: String? {
            switch self {
            case .any: nil
            case .pdf: "pdf"
            case .html: "html"
            case .text: "txt"
            }
        }
    }

    struct Plan: Equatable {
        let seed: String
        let query: String
        let scope: String?
        let notes: [String]
    }

    enum Problem: Error, Equatable {
        case input, scope
        var message: String {
            switch self {
            case .input: "Enter a valid value for the selected input type. Quotes, hidden controls and search operators are not accepted."
            case .scope: "Use a domain such as example.com, without a URL, path, port or search operators."
            }
        }
    }

    static func build(
        input: String, kind: Kind, scope: String = "", document: DocumentKind = .any,
        region: PhoneRegion = .international
    ) -> Result<Plan, Problem> {
        guard input.utf8.count <= 512, safe(input), safe(scope), scope.utf8.count <= 253,
              let seed = normalize(input, kind: kind, region: region) else { return .failure(.input) }
        let trimmedScope = scope.trimmingCharacters(in: .whitespaces)
        let host = trimmedScope.isEmpty ? nil : domain(trimmedScope)
        guard trimmedScope.isEmpty || host != nil else { return .failure(.scope) }
        var parts = ["\"" + seed + "\""]
        if let host {
            parts.append("site:" + host)
        }
        if let suffix = document.suffix {
            parts.append("filetype:" + suffix)
        }
        var notes = [
            "Prepared locally. Nothing is sent until you use this query in a search service.",
            "Search results can be incomplete or outdated. A shared name or handle does not prove shared identity.",
        ]
        if kind == .phone {
            notes.append("Phone formatting only; existence, ownership, carrier and location have not been checked.")
        }
        if host != nil {
            notes.append("The site filter may include subdomains; search engines decide how operators are interpreted.")
        }
        return .success(Plan(seed: seed, query: parts.joined(separator: " "), scope: host, notes: notes))
    }

    /// DNS labels only: no URL parsing, implicit host extraction, network resolution or IP inference.
    static func domain(_ input: String) -> String? {
        let value = input.lowercased()
        guard value.utf8.count <= 253, value.contains("."),
              value.range(of: #"\A[a-z0-9.-]+\z"#, options: .regularExpression) != nil else { return nil }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" }),
              let last = labels.last, last.contains(where: \.isLetter) else { return nil }
        return value
    }

    private static func normalize(_ input: String, kind: Kind, region: PhoneRegion) -> String? {
        let value = input.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .username: return BeholderProvider.username(value)
        case .domain: return domain(value)
        case .phone: return phone(value, region: region)
        case .email:
            let address = value.lowercased().hasPrefix("mailto:") ? String(value.dropFirst(7)) : value
            let pieces = address.split(separator: "@", omittingEmptySubsequences: false)
            guard pieces.count == 2, let host = domain(String(pieces[1])),
                  pieces[0].range(of: #"\A[A-Za-z0-9][A-Za-z0-9._%+-]{0,63}\z"#, options: .regularExpression) != nil,
                  !pieces[0].contains(".."), !pieces[0].hasSuffix(".") else { return nil }
            return String(pieces[0]) + "@" + host
        case .name:
            let allowed = CharacterSet.letters.union(.nonBaseCharacters).union(CharacterSet(charactersIn: " '-’."))
            guard (2 ... 120).contains(value.count), value.unicodeScalars.allSatisfy(allowed.contains),
                  value.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return nil }
            return value.split(separator: " ").joined(separator: " ")
        }
    }

    private static func phone(_ input: String, region: PhoneRegion) -> String? {
        let value = input.lowercased().hasPrefix("tel:") ? String(input.dropFirst(4)) : input
        guard value.range(of: #"\A\+?[0-9 ().-]+\z"#, options: .regularExpression) != nil else { return nil }
        let digits = value.filter(\.isNumber)
        if value.hasPrefix("+") {
            guard (7 ... 15).contains(digits.count), digits.first != "0" else { return nil }
            return "+" + digits
        }
        guard region == .australia, digits.count == 10, digits.first == "0",
              ["2", "3", "4", "7", "8"].contains(String(digits.dropFirst().prefix(1))) else { return nil }
        return "+61" + digits.dropFirst()
    }

    private static func safe(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                && $0.properties.generalCategory != .format
        }
    }
}
