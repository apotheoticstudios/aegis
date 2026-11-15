import Foundation

/// Which of the owner's shortcuts a spoken name means (#203). Speech splits and mishears names: "Jarvis Dev" is the
/// shortcut "JarvisDev" (the same letters), and "Java's Dev" is close enough to be it misheard, which is only offered.
public enum ShortcutName {
    public enum Match: Sendable, Equatable {
        /// The same letters and digits: run as named.
        case same(String)
        /// The one name a mishearing away: ask first, never run.
        case close(String)
    }

    public static func match(_ said: String, in names: [String]) -> Match? {
        let key = folded(said)
        guard !key.isEmpty else { return nil }
        let exact = names.first { $0.caseInsensitiveCompare(said) == .orderedSame }
        if let same = exact ?? names.first(where: { folded($0) == key }) {
            return .same(same)
        }
        // About one letter in four may differ; two near names are too close to guess between.
        let near = names.filter { key.count >= 3 && distance(folded($0), key) <= max(1, key.count / 4) }
        return near.count == 1 ? .close(near[0]) : nil
    }

    /// Lowercased letters and digits only.
    static func folded(_ name: String) -> [Character] {
        name.lowercased().filter { $0.isLetter || $0.isNumber }.map(\.self)
    }

    /// Levenshtein distance.
    static func distance(_ one: [Character], _ two: [Character]) -> Int {
        var row = Array(0 ... two.count)
        for (index, letter) in one.enumerated() {
            var next = [index + 1]
            for (other, against) in two.enumerated() {
                next.append(min(row[other + 1] + 1, next[other] + 1, row[other] + (letter == against ? 0 : 1)))
            }
            row = next
        }
        return row[two.count]
    }
}
