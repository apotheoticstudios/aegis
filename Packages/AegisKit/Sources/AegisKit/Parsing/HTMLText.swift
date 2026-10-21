import Foundation

/// A small HTML tokenizer matching the Python reader's visible text policy.
enum HTMLText {
    static func convert(_ html: String) -> String {
        var cursor = html.startIndex, chunks: [String] = [], hidden: [String] = []
        while cursor < html.endIndex {
            // Script and style use raw text: '<' inside their contents is not a tag.
            if let raw = hidden.last, raw == "script" || raw == "style" {
                guard let closing = html.range(of: "</" + raw, options: .caseInsensitive, range: cursor ..< html.endIndex) else { break }
                cursor = closing.lowerBound
            }
            if html[cursor] != "<" {
                let end = html[cursor...].firstIndex(of: "<") ?? html.endIndex
                if hidden.isEmpty {
                    chunks.append(entities(String(html[cursor ..< end])))
                }
                cursor = end
                continue
            }
            if html[cursor...].hasPrefix("<!--") {
                guard let end = html.range(of: "-->", range: cursor ..< html.endIndex) else { break }
                cursor = end.upperBound
                continue
            }
            guard let tag = tag(html, at: cursor) else {
                // A literal '<' (e.g. '2 < 3') is data, not markup.
                if hidden.isEmpty {
                    chunks.append("<")
                }
                cursor = html.index(after: cursor)
                continue
            }
            updateHidden(tag, hidden: &hidden)
            cursor = tag.end
        }
        return chunks.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private struct Tag {
        let name: String
        let closing: Bool
        let selfClosing: Bool
        let end: String.Index
    }

    private static func updateHidden(_ tag: Tag, hidden: inout [String]) {
        if tag.closing {
            if let index = hidden.firstIndex(of: tag.name) {
                hidden.removeSubrange(index...)
            }
        } else if !tag.selfClosing {
            if tag.name == "body" {
                hidden.removeAll()
            } else if ["style", "script", "head", "title"].contains(tag.name) {
                hidden.append(tag.name)
            }
        }
    }

    private static func tag(_ html: String, at start: String.Index) -> Tag? {
        let contentStart = html.index(after: start)
        guard contentStart < html.endIndex else { return nil }
        let closing = html[contentStart] == "/"
        let nameStart = closing ? html.index(after: contentStart) : contentStart
        guard nameStart < html.endIndex,
              html[nameStart].isLetter || html[nameStart] == "!" || html[nameStart] == "?" else { return nil }
        var end = contentStart, quote: Character?
        while end < html.endIndex {
            let char = html[end]
            if let quoted = quote {
                if char == quoted {
                    quote = nil
                }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == ">" {
                break
            }
            end = html.index(after: end)
        }
        guard end < html.endIndex else { return nil }
        let token = html[nameStart ..< end]
        let name = token.prefix { $0.isLetter || $0.isNumber || $0 == "-" }.lowercased()
        return Tag(name: name, closing: closing, selfClosing: token.hasSuffix("/"), end: html.index(after: end))
    }

    private static func entities(_ text: String) -> String {
        var result = "", cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor] == "&" else { result.append(text[cursor]); cursor = text.index(after: cursor); continue }
            let start = text.index(after: cursor)
            if start < text.endIndex, text[start] == "#", let numeric = numericReference(text, at: start) {
                result += numeric.text; cursor = numeric.end; continue
            }
            var end = start, length = 0
            while end < text.endIndex, length < 32 {
                let char = text[end]
                guard char.isASCII, char.isLetter || char.isNumber || char == ";" else { break }
                end = text.index(after: end); length += 1
                if char == ";" {
                    break
                }
            }
            var match = end, found = false
            while match > start {
                if let value = named[String(text[start ..< match])] {
                    result += value; cursor = match; found = true; break
                }
                match = text.index(before: match)
            }
            if !found {
                result.append("&"); cursor = start
            }
        }
        return result
    }

    private static func isReferenceDigit(_ char: Character, hex: Bool) -> Bool {
        char.isASCII && (hex ? char.isHexDigit : char.isNumber)
    }

    private static func numericReference(_ text: String, at start: String.Index) -> (text: String, end: String.Index)? {
        var cursor = text.index(after: start)
        let hex = cursor < text.endIndex && (text[cursor] == "x" || text[cursor] == "X")
        if hex {
            cursor = text.index(after: cursor)
        }
        let digits = cursor
        while cursor < text.endIndex, isReferenceDigit(text[cursor], hex: hex) {
            cursor = text.index(after: cursor)
        }
        guard digits < cursor else { return nil }
        let number = UInt32(text[digits ..< cursor], radix: hex ? 16 : 10) ?? 0xFFFD
        if cursor < text.endIndex, text[cursor] == ";" {
            cursor = text.index(after: cursor)
        }
        let c1: [UInt32: UInt32] = [
            128: 0x20AC, 130: 0x201A, 131: 0x0192, 132: 0x201E, 133: 0x2026, 134: 0x2020, 135: 0x2021,
            136: 0x02C6, 137: 0x2030, 138: 0x0160, 139: 0x2039, 140: 0x0152, 142: 0x017D, 145: 0x2018,
            146: 0x2019, 147: 0x201C, 148: 0x201D, 149: 0x2022, 150: 0x2013, 151: 0x2014, 152: 0x02DC,
            153: 0x2122, 154: 0x0161, 155: 0x203A, 156: 0x0153, 158: 0x017E, 159: 0x0178,
        ]
        let value = c1[number] ?? number
        if value == 0 || (0xD800 ... 0xDFFF).contains(value) || value > 0x10FFFF {
            return ("\u{FFFD}", cursor)
        }
        let invisible = (1 ... 8).contains(value) || value == 11 || (14 ... 31).contains(value) || value == 127
            || (0xFDD0 ... 0xFDEF).contains(value) || value & 0xFFFF >= 0xFFFE
        if invisible {
            return ("", cursor)
        }
        return (UnicodeScalar(value).map(String.init) ?? "\u{FFFD}", cursor)
    }
}
