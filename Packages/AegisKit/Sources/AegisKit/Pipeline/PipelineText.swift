import Foundation

/// Python counts Unicode code points, rather than Swift's extended grapheme clusters.
func scalarPrefix(_ text: String, _ count: Int) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.prefix(max(0, count))))
}

func scalarLess(_ lhs: String, _ rhs: String) -> Bool {
    lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars)
}

func exactText(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): true
    case let (left?, right?): left.utf8.elementsEqual(right.utf8)
    default: false
    }
}

func folded(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
}

func matches(_ pattern: String, _ text: String, insensitive: Bool = false) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: insensitive ? [.caseInsensitive] : []) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
        Range($0.range, in: text).map { String(text[$0]) }
    }
}

/// Python-compatible JSON string spelling, including its additional physical line separators.
func jsonString(_ text: String, ascii: Bool = false) -> String {
    var result = "\""
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 34: result += "\\\""
        case 92: result += "\\\\"
        case 8: result += "\\b"
        case 9: result += "\\t"
        case 10: result += "\\n"
        case 12: result += "\\f"
        case 13: result += "\\r"
        case 0 ..< 32, 0x85, 0x2028, 0x2029:
            result += String(format: "\\u%04x", scalar.value)
        default:
            if ascii, scalar.value > 127 {
                if scalar.value <= 0xFFFF {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    let value = scalar.value - 0x10000
                    result += String(format: "\\u%04x\\u%04x", 0xD800 + (value >> 10), 0xDC00 + (value & 1023))
                }
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
    }
    return result + "\""
}

/// Sorted, ASCII JSON provides the same deterministic equal-capture revision tie break as Python.
func revisionKey(_ event: Event) throws -> String {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any] ?? [:]
    object.removeValue(forKey: "observations")
    func dump(_ value: Any) -> String {
        if let string = value as? String {
            return jsonString(string, ascii: true)
        }
        if let array = value as? [Any] {
            return "[" + array.map(dump).joined(separator: ", ") + "]"
        }
        if let dict = value as? [String: Any] {
            return "{" + dict.keys.sorted(by: scalarLess).map { jsonString($0, ascii: true) + ": " + dump(dict[$0] ?? NSNull()) }
                .joined(separator: ", ") + "}"
        }
        return "null"
    }
    return dump(object)
}

/// Foundation's Darwin bridges autorelease temporary objects. Corelibs Foundation uses ARC directly.
/// Drain each streaming iteration on Darwin so temporary Objective-C allocations cannot grow with the stream.
func pipelinePool<Result>(_ body: () throws -> Result) rethrows -> Result {
    #if canImport(ObjectiveC)
        try autoreleasepool(invoking: body)
    #else
        try body()
    #endif
}
