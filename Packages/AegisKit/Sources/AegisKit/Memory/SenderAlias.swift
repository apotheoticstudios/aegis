import Foundation

/// An owner-asserted handle/name fact. Only complete assertions become identity corrections.
struct SenderAlias {
    let handle: String
    let name: String
    let key: String

    static func parse(_ text: String) -> SenderAlias? {
        let line = text.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .replacingOccurrences(of: "’", with: "'")
        let patterns = [
            (
                #"^(?:(?:the |this )?(?:phone number|number|email address|email)\s+)?(.+?)\s+(?:is|belongs to)\s+([\p{L}][\p{L} .'-]{0,79})$"#,
                false
            ),
            (#"^([\p{L}][\p{L} .'-]{0,79}?)'s\s+(?:phone number|number|email address|email)\s+is\s+(.+)$"#, true),
        ]
        for (pattern, reverse) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let first = Range(match.range(at: 1), in: line), let second = Range(match.range(at: 2), in: line)
            else { continue }
            let handle = String(line[reverse ? second : first]).trimmingCharacters(in: .whitespaces)
            let name = String(line[reverse ? first : second]).trimmingCharacters(in: .whitespaces)
            let words = Set(name.lowercased().split(separator: " ").map(String.init))
            guard words.isDisjoint(with: ["not", "maybe", "probably", "unknown", "someone", "you", "me", "my", "your", "or", "and"]),
                  let key = handleKey(handle) else { continue }
            return SenderAlias(handle: handle, name: name, key: key)
        }
        return nil
    }

    static func handleKey(_ text: String) -> String? {
        let handle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = #"^(?:mailto:)?[^\s@]+@[^\s@]+\.[^\s@]+$"#
        let phone = #"^(?:tel:)?\+?[0-9(). -]{7,30}$"#
        guard handle.range(of: email, options: [.regularExpression, .caseInsensitive]) != nil
            || (handle.range(of: phone, options: [.regularExpression, .caseInsensitive]) != nil
                && (7 ... 15).contains(handle.filter(\.isNumber).count))
        else { return nil }
        return ContactIndex([]).key(for: handle)
    }
}

extension MemoryBook {
    var senderAliases: [SenderAlias] {
        notes.filter { $0.kind == .fact }.compactMap { SenderAlias.parse($0.text) }
    }

    func senderAnswer(_ question: String) -> String? {
        let patterns = [
            #"^who(?: is|'s) (.+)$"#,
            #"^whose (?:number|email)(?: is)? (.+)$"#,
            #"^who does (.+) belong to$"#,
        ]
        let line = question.trimmingCharacters(in: CharacterSet(charactersIn: "?.! "))
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line), let key = SenderAlias.handleKey(String(line[range])),
                  let alias = senderAliases.last(where: { $0.key == key }) else { continue }
            return "That belongs to " + alias.name + "."
        }
        return nil
    }
}
