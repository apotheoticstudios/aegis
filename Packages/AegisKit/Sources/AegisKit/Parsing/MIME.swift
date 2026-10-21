import Foundation

struct MailHeaders {
    var fields: [(String, String)] = []

    func values(_ name: String) -> [String] {
        fields.filter { $0.0 == name }.map { Self.decodeWords($0.1) }
    }

    func first(_ name: String) -> String? {
        values(name).first
    }

    /// Raw unfolding is also the fallback: no structured header parser can reject the message.
    static func read(_ bytes: [UInt8], range: Range<Int>) -> (MailHeaders, Int) {
        var headers = MailHeaders(), cursor = range.lowerBound
        while cursor < range.upperBound {
            let line = MIME.line(bytes, at: cursor, end: range.upperBound)
            var end = line.upperBound
            while end > cursor, bytes[end - 1] == 10 || bytes[end - 1] == 13 {
                end -= 1
            }
            if end == cursor {
                return (headers, line.upperBound)
            }
            // Replacement decoding preserves malformed headers as inert data.
            // swiftlint:disable:next optional_data_string_conversion
            let text = String(decoding: bytes[cursor ..< end], as: UTF8.self)
            if bytes[cursor] == 32 || bytes[cursor] == 9 {
                if !headers.fields.isEmpty {
                    headers.fields[headers.fields.count - 1].1 += " " + text.trimmingCharacters(in: .whitespaces)
                }
            } else {
                guard let colon = text.firstIndex(of: ":") else { return (headers, cursor) }
                let name = text[..<colon]
                guard !name.isEmpty, name.utf8.allSatisfy({ (33 ... 126).contains($0) && $0 != 58 }) else { return (headers, cursor) }
                headers.fields.append((name.lowercased(), String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
            cursor = line.upperBound
        }
        return (headers, cursor)
    }

    static func decodeWords(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "=\\?([^?\\s]+)\\?([bBqQ])\\?([^?]*)\\?=") else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = "", cursor = text.startIndex, previousWasWord = false
        for match in matches {
            guard let whole = Range(match.range, in: text), let charset = Range(match.range(at: 1), in: text),
                  let mode = Range(match.range(at: 2), in: text), let payload = Range(match.range(at: 3), in: text) else { continue }
            let gap = String(text[cursor ..< whole.lowerBound])
            if !previousWasWord || !gap.allSatisfy(\.isWhitespace) {
                result += gap
            }
            let raw = Array(text[payload].utf8)
            let decoded = text[mode].lowercased() == "b" ? MIME.base64(raw) : MIME.quotedPrintable(raw.map { $0 == 95 ? 32 : $0 })
            result += MailCharset.decode(decoded, charset: String(text[charset]))
            cursor = whole.upperBound
            previousWasWord = true
        }
        return result + text[cursor...]
    }

    static func recipients(_ text: String) -> [String] {
        var entries: [String] = [], current = "", state = RecipientState()
        for char in text {
            if state.isSeparator(char) {
                appendRecipient(current, to: &entries)
                current = ""
            } else {
                current.append(char)
            }
        }
        appendRecipient(current, to: &entries)
        return entries
    }

    private static func appendRecipient(_ text: String, to entries: inout [String]) {
        let entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entry.isEmpty {
            entries.append(entry)
        }
    }

    private struct RecipientState {
        var quoted = false, escaped = false, angle = 0, comment = 0

        mutating func isSeparator(_ char: Character) -> Bool {
            if escaped {
                escaped = false
                return false
            }
            if char == "\\" {
                escaped = true
                return false
            }
            if char == "\"", comment == 0 {
                quoted.toggle()
            }
            guard !quoted else { return false }
            switch char {
            case "(": comment += 1
            case ")": comment = max(0, comment - 1)
            default: break
            }
            guard comment == 0 else { return false }
            return isAddressSeparator(char)
        }

        private mutating func isAddressSeparator(_ char: Character) -> Bool {
            switch char {
            case "<": angle += 1
            case ">": angle = max(0, angle - 1)
            default: break
            }
            return char == "," && angle == 0
        }
    }
}

enum MIME {
    struct Part {
        var headers: MailHeaders
        var plain: String?
        var html: String?
        var encrypted = false
    }

    static func line(_ bytes: [UInt8], at start: Int, end: Int) -> Range<Int> {
        var cursor = start
        while cursor < end {
            cursor += 1
            if bytes[cursor - 1] == 10 {
                break
            }
        }
        return start ..< cursor
    }

    static func parse(_ bytes: [UInt8], range: Range<Int>, nested: Bool = false, depth: Int = 0) -> Part {
        let (headers, bodyStart) = MailHeaders.read(bytes, range: range)
        var part = Part(headers: headers)
        let type = parameters(headers.first("content-type") ?? "text/plain")
        part.encrypted = ["application/pkcs7-mime", "application/x-pkcs7-mime", "multipart/encrypted"].contains(type.kind)
        guard !part.encrypted, parameters(headers.first("content-disposition") ?? "").kind != "attachment" else { return part }
        if type.kind.hasPrefix("multipart/"), let boundary = type.values["boundary"], !boundary.isEmpty {
            parseMultipart(bytes, range: bodyStart ..< range.upperBound, boundary: boundary, depth: depth, into: &part)
        } else if type.kind == "text/plain" || type.kind == "text/html" {
            decodeText(bytes, range: bodyStart ..< range.upperBound, nested: nested, type: type, into: &part)
        }
        return part
    }

    private static func parseMultipart(
        _ bytes: [UInt8], range: Range<Int>, boundary: String, depth: Int, into part: inout Part
    ) {
        // A depth bound prevents hostile MIME from exhausting the stack; ordinary nested parts are unchanged.
        guard depth < 100 else { return }
        let opening = Array(("--" + boundary).utf8), closing = opening + [45, 45]
        var cursor = range.lowerBound, childStart: Int?
        while cursor < range.upperBound {
            let row = line(bytes, at: cursor, end: range.upperBound)
            var markerEnd = row.upperBound
            while markerEnd > cursor, [10, 13, 32, 9].contains(bytes[markerEnd - 1]) {
                markerEnd -= 1
            }
            let marker = bytes[cursor ..< markerEnd]
            let isOpening = marker.elementsEqual(opening), isClosing = marker.elementsEqual(closing)
            if isOpening || isClosing {
                if let start = childStart {
                    merge(parse(bytes, range: start ..< cursor, nested: true, depth: depth + 1), into: &part)
                }
                if isClosing {
                    return
                }
                childStart = row.upperBound
            }
            cursor = row.upperBound
        }
        if let start = childStart {
            merge(parse(bytes, range: start ..< range.upperBound, nested: true, depth: depth + 1), into: &part)
        }
    }

    private static func decodeText(
        _ bytes: [UInt8], range: Range<Int>, nested: Bool,
        type: (kind: String, values: [String: String]), into part: inout Part
    ) {
        let bodyStart = range.lowerBound
        var end = range.upperBound
        if nested, end > bodyStart, bytes[end - 1] == 10 {
            end -= 1
            if end > bodyStart, bytes[end - 1] == 13 {
                end -= 1
            }
        }
        let raw = Array(bytes[bodyStart ..< end])
        let encoding = part.headers.first("content-transfer-encoding")?.lowercased()
        let payload = encoding == "base64" ? base64(raw) : encoding == "quoted-printable" ? quotedPrintable(raw) : raw
        let text = MailCharset.decode(payload, charset: type.values["charset"] ?? "utf-8")
        if type.kind == "text/plain" {
            part.plain = text
        } else {
            part.html = HTMLText.convert(text)
        }
    }

    private static func merge(_ child: Part, into part: inout Part) {
        part.plain = part.plain ?? child.plain
        part.html = part.html ?? child.html
        part.encrypted = part.encrypted || child.encrypted
    }

    static func parameters(_ text: String) -> (kind: String, values: [String: String]) {
        var pieces: [String] = [], current = "", quoted = false, escaped = false
        for char in text {
            if escaped {
                current.append(char); escaped = false; continue
            }
            if quoted, char == "\\" {
                escaped = true; continue
            }
            if char == "\"" {
                quoted.toggle(); continue
            }
            if char == ";", !quoted {
                pieces.append(current); current = ""
            } else {
                current.append(char)
            }
        }
        pieces.append(current)
        var values: [String: String] = [:]
        for item in pieces.dropFirst() {
            guard let equal = item.firstIndex(of: "=") else { continue }
            values[item[..<equal].trimmingCharacters(in: .whitespaces).lowercased()] =
                item[item.index(after: equal)...].trimmingCharacters(in: .whitespaces)
        }
        return (pieces.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "", values)
    }

    static func base64(_ bytes: [UInt8]) -> [UInt8] {
        var clean = bytes
            .filter { (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57).contains($0) || [43, 47, 61].contains($0) }
        while clean.count % 4 != 0 {
            clean.append(61)
        }
        return Data(base64Encoded: Data(clean), options: .ignoreUnknownCharacters).map { [UInt8]($0) } ?? bytes
    }

    static func quotedPrintable(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = [], cursor = 0
        while cursor < bytes.count {
            if bytes[cursor] == 61 {
                if cursor + 1 < bytes.count, bytes[cursor + 1] == 10 {
                    cursor += 2; continue
                }
                if cursor + 2 < bytes.count {
                    if bytes[cursor + 1] == 13, bytes[cursor + 2] == 10 {
                        cursor += 3; continue
                    }
                    if let high = hex(bytes[cursor + 1]), let low = hex(bytes[cursor + 2]) {
                        result.append(high * 16 + low); cursor += 3; continue
                    }
                }
            }
            result.append(bytes[cursor]); cursor += 1
        }
        return result
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48 ... 57: byte - 48
        case 65 ... 70: byte - 55
        case 97 ... 102: byte - 87
        default: nil
        }
    }
}

enum MailCharset {
    /// Whether this platform's Foundation can decode the named charset or alias.
    static func isSupported(_ charset: String) -> Bool {
        let name = charset.lowercased().replacingOccurrences(of: "_", with: "-")
        guard let rawValue = encodings[name] else { return false }
        return supportedEncodings.contains(rawValue)
    }

    /// Probe each encoding once, sharing results across aliases. Immutable value storage
    /// keeps lazy initialization safe for concurrent callers in Swift 6.
    private static let supportedEncodings: Set<UInt> = Set(Set(encodings.values).filter { rawValue in
        let sample: [UInt8] = switch rawValue {
        case 0x0000_000A: [0xFE, 0xFF, 0, 65] // UTF-16 with a BOM.
        case 0x9000_0100: [0, 65] // UTF-16BE.
        case 0x9400_0100: [65, 0] // UTF-16LE.
        case 0x8C00_0100: [0, 0, 0xFE, 0xFF, 0, 0, 0, 65] // UTF-32 with a BOM.
        case 0x9800_0100: [0, 0, 0, 65] // UTF-32BE.
        case 0x9C00_0100: [65, 0, 0, 0] // UTF-32LE.
        default: [65]
        }
        return String(data: Data(sample), encoding: String.Encoding(rawValue: rawValue)) != nil
    })

    static func decode(_ bytes: [UInt8], charset: String) -> String {
        let name = charset.lowercased().replacingOccurrences(of: "_", with: "-")
        guard let encoding = encoding(name), encoding != .utf8 else {
            // Replacement decoding is intentional for UTF-8 and unknown charsets.
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: bytes, as: UTF8.self)
        }
        if let text = String(data: Data(bytes), encoding: encoding) {
            return text
        }
        // Salvage only the first 64 KiB after whole-buffer decoding fails. This bounds
        // per-character Foundation allocations; the remaining malformed body becomes one U+FFFD.
        let limit = min(bytes.count, 64 * 1024)
        var result = "", cursor = 0
        let wide = name.hasPrefix("utf-16") || name.hasPrefix("utf-32")
        while cursor < limit {
            var found = false
            for length in 1 ... min(4, limit - cursor) {
                if let text = String(data: Data(bytes[cursor ..< (cursor + length)]), encoding: encoding), !text.isEmpty {
                    result += text; cursor += length; found = true; break
                }
            }
            if !found {
                result += "\u{FFFD}"; cursor += min(wide ? (name.hasPrefix("utf-32") ? 4 : 2) : 1, limit - cursor)
            }
        }
        if limit < bytes.count {
            result += "\u{FFFD}"
        }
        return result
    }

    /// IANA names for Foundation's NSString encodings and common mail aliases. Numeric identifiers
    /// keep this portable to swift-corelibs-foundation without platform-specific charset APIs.
    private static let encodings: [String: UInt] = [
        "ascii": 0x0000_0001, "big-5": 0x8000_0A03, "big5": 0x8000_0A03, "big5-hkscs": 0x8000_0A06, "cp1250": 0x0000_000F,
        "cp1251": 0x0000_000B, "cp1252": 0x0000_000C, "cp1253": 0x0000_000D, "cp1254": 0x0000_000E, "cp1255": 0x8000_0505,
        "cp1256": 0x8000_0506, "cp1257": 0x8000_0507, "cp1258": 0x8000_0508, "cp437": 0x8000_0400, "cp737": 0x8000_0405,
        "cp775": 0x8000_0406, "cp850": 0x8000_0410, "cp851": 0x8000_0411, "cp852": 0x8000_0412, "cp855": 0x8000_0413,
        "cp857": 0x8000_0414, "cp860": 0x8000_0415, "cp861": 0x8000_0416, "cp862": 0x8000_0417, "cp863": 0x8000_0418,
        "cp864": 0x8000_0419, "cp865": 0x8000_041A, "cp866": 0x8000_041B, "cp869": 0x8000_041C, "cp874": 0x8000_041D,
        "cp932": 0x0000_0008, "cp936": 0x8000_0421, "cp949": 0x8000_0422, "cp950": 0x8000_0423, "euc-cn": 0x8000_0930,
        "euc-jp": 0x0000_0003, "euc-kr": 0x8000_0940, "euc-tw": 0x8000_0931, "eucjp": 0x0000_0003, "gb18030": 0x8000_0632,
        "gb2312": 0x8000_0930, "gbk": 0x8000_0631, "hz": 0x8000_0A05, "hz-gb-2312": 0x8000_0A05, "ibm037": 0x8000_0C02,
        "iso-2022-cn": 0x8000_0830, "iso-2022-jp": 0x0000_0015, "iso-2022-jp-1": 0x8000_0822, "iso-2022-jp-2": 0x8000_0821,
        "iso-2022-kr": 0x8000_0840, "iso-8859-1": 0x0000_0005, "iso-8859-10": 0x8000_020A, "iso-8859-11": 0x8000_020B,
        "iso-8859-13": 0x8000_020D, "iso-8859-14": 0x8000_020E, "iso-8859-15": 0x8000_020F, "iso-8859-16": 0x8000_0210,
        "iso-8859-2": 0x0000_0009, "iso-8859-3": 0x8000_0203, "iso-8859-4": 0x8000_0204, "iso-8859-5": 0x8000_0205,
        "iso-8859-6": 0x8000_0206, "iso-8859-7": 0x8000_0207, "iso-8859-8": 0x8000_0208, "iso-8859-9": 0x8000_0209,
        "iso8859-1": 0x0000_0005, "iso8859-2": 0x0000_0009, "koi8-r": 0x8000_0A02, "koi8-u": 0x8000_0A08,
        "ks-c-5601-1987": 0x8000_0940, "latin-1": 0x0000_0005, "latin1": 0x0000_0005, "latin2": 0x0000_0009, "latin9": 0x8000_020F,
        "mac-roman": 0x0000_001E, "macintosh": 0x0000_001E, "shift-jis": 0x8000_0A01, "shiftjis": 0x8000_0A01, "sjis": 0x0000_0008,
        "unicode-1-1-utf-8": 0x0000_0004, "us-ascii": 0x0000_0001, "utf-16": 0x0000_000A, "utf-16be": 0x9000_0100,
        "utf-16le": 0x9400_0100, "utf-32": 0x8C00_0100, "utf-32be": 0x9800_0100, "utf-32le": 0x9C00_0100, "utf-7": 0x8400_0100,
        "utf-8": 0x0000_0004, "utf16": 0x0000_000A, "utf32": 0x8C00_0100, "utf8": 0x0000_0004, "windows-1250": 0x0000_000F,
        "windows-1251": 0x0000_000B, "windows-1252": 0x0000_000C, "windows-1253": 0x0000_000D, "windows-1254": 0x0000_000E,
        "windows-1255": 0x8000_0505, "windows-1256": 0x8000_0506, "windows-1257": 0x8000_0507, "windows-1258": 0x8000_0508,
        "x-mac-arabic": 0x8000_0004, "x-mac-celtic": 0x8000_0027, "x-mac-centraleurroman": 0x8000_001D, "x-mac-croatian": 0x8000_0024,
        "x-mac-cyrillic": 0x8000_0007, "x-mac-devanagari": 0x8000_0009, "x-mac-dingbats": 0x8000_0022, "x-mac-farsi": 0x8000_008C,
        "x-mac-gaelic": 0x8000_0028, "x-mac-greek": 0x8000_0006, "x-mac-gujarati": 0x8000_000B, "x-mac-gurmukhi": 0x8000_000A,
        "x-mac-hebrew": 0x8000_0005, "x-mac-icelandic": 0x8000_0025, "x-mac-inuit": 0x8000_00EC, "x-mac-japanese": 0x8000_0001,
        "x-mac-korean": 0x8000_0003, "x-mac-roman-latin1": 0x8000_0A04, "x-mac-romanian": 0x8000_0026,
        "x-mac-simp-chinese": 0x8000_0019, "x-mac-symbol": 0x0000_0006, "x-mac-thai": 0x8000_0015, "x-mac-tibetan": 0x8000_001A,
        "x-mac-trad-chinese": 0x8000_0002, "x-mac-turkish": 0x8000_0023, "x-mac-ukrainian": 0x8000_0098, "x-nextstep": 0x0000_0002,
    ]

    private static func encoding(_ name: String) -> String.Encoding? {
        encodings[name].map { String.Encoding(rawValue: $0) }
    }
}
