import Foundation

/// Bounded source text centered on the requested evidence, rather than always on the first paragraph.
enum AskExcerpt {
    static func text(_ body: String, limit: Int, terms: [String]) -> String {
        guard body.unicodeScalars.count > limit else { return body }
        let prioritized = terms.sorted { $0.contains(where: \.isNumber) && !$1.contains(where: \.isNumber) }
        let range = prioritized.lazy.compactMap { body.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.first
        let anchor = range.map { body.unicodeScalars.distance(from: body.unicodeScalars.startIndex, to: $0.lowerBound) } ?? 0
        let scalars = Array(body.unicodeScalars)
        let start = max(0, min(anchor - limit / 3, scalars.count - limit))
        let end = min(scalars.count, start + limit)
        return (start > 0 ? "…" : "") + String(String.UnicodeScalarView(scalars[start ..< end])) + (end < scalars.count ? "…" : "")
    }
}
