import Foundation

/// A single approved public search. Only `query` may leave the Mac; no history or personal context is carried.
public struct PublicLookupPlan: Codable, Sendable, Hashable {
    public let id: UUID
    public let query: String
    public let expiresAt: Date
    public init(id: UUID, query: String, expiresAt: Date) {
        self.id = id; self.query = query; self.expiresAt = expiresAt
    }
}

/// A plain public search excerpt, untrusted data rather than instructions. No URL is needed or followed.
public struct PublicSource: Codable, Sendable, Hashable {
    public let title: String
    public let excerpt: String
    public init(title: String, excerpt: String) {
        self.title = title; self.excerpt = excerpt
    }
}

enum PublicLookupPolicy {
    static func query(_ question: String, names: Set<String>) -> String? {
        let privacyText = question.replacingOccurrences(
            of: #"^\s*(?:what is|what's)\s+"#, with: "", options: [.regularExpression, .caseInsensitive]
        )
        guard question.unicodeScalars.count <= 500,
              !question.unicodeScalars
              .contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }),
              !CloudHandOff.isPersonal(privacyText, names: names),
              question.range(
                  of: #"https?://|www\.|@"#,
                  options: [.regularExpression, .caseInsensitive]
              ) == nil else { return nil }
        let query = question.replacingOccurrences(
            of: #"^\s*(?:(?:please|can you|could you)\s+)?(?:search (?:the )?(?:web|internet)(?: for)?|search for|look up|google|browse for)\s+"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4 ... 300).contains(query.unicodeScalars.count),
              !["this", "that", "it", "them", "look it up", "search online", "on today", "on tomorrow"].contains(query.lowercased())
        else { return nil }
        return query
    }

    static func requested(_ question: String) -> Bool {
        question.range(
            of: #"\b(?:search|look up|google|browse|latest|current|currently|news|weather|forecast|prices?|scores?|right now)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func valid(_ sources: [PublicSource]) -> Bool {
        !sources.isEmpty && sources.count <= 5 && sources.allSatisfy {
            !$0.title.isEmpty && $0.title.unicodeScalars.count <= 200
                && $0.title.range(
                    of: #"[a-z][a-z0-9+.-]*://|www\.|mailto:|tel:|\]\(|<a\b"#,
                    options: [.regularExpression, .caseInsensitive]
                ) == nil
                && !$0.excerpt.isEmpty && $0.excerpt.unicodeScalars.count <= 1200
                && !($0.title + $0.excerpt).unicodeScalars.contains { scalar in
                    scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
                }
        }
    }
}
