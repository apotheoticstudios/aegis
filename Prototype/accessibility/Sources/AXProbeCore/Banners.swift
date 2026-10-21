import Foundation

/// One accessibility element reduced to metadata. There is deliberately no field for text, not even
/// identifiers (an app may put a name in one): only lengths, and which of the owner's own test markers
/// the element's text contained. Nothing built from a snapshot can print words.
public struct NodeSnapshot: Sendable, Equatable {
    public var role: String?
    public var subrole: String?
    /// Characters in the element's identifier, if it has one.
    public var identifierLength: Int?
    /// Characters of text the element exposes (its value, title or description), or nil if none.
    public var textLength: Int?
    /// Labels ("app", "title", "body") of the owner's expected markers found in this element's text.
    public var matched: [String]
    public var children: [NodeSnapshot]

    public init(
        role: String?,
        subrole: String? = nil,
        identifierLength: Int? = nil,
        textLength: Int? = nil,
        matched: [String] = [],
        children: [NodeSnapshot] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.identifierLength = identifierLength
        self.textLength = textLength
        self.matched = matched
        self.children = children
    }
}

/// What one banner exposes, without its words.
public struct BannerSummary: Sendable, Equatable {
    public var subrole: String?
    /// Lengths of the banner's text elements, in reading order.
    public var textLengths: [Int]
    public var buttons: Int
    public var images: Int
    /// Labels of the owner's expected markers found anywhere in the banner.
    public var found: Set<String>

    /// True when Accessibility exposes any text at all.
    public var hasText: Bool {
        textLengths.contains { $0 > 0 }
    }
}

/// The owner's own test markers, such as a notification title they chose. Matching tells whether a
/// field is readable without ever printing what it says.
public enum Markers {
    public static let labels = ["app", "title", "body"]

    /// Labels whose expected marker appears in `text` (case-insensitive). Empty markers never match.
    public static func labels(in text: String, expected: [String: String]) -> [String] {
        var labels: [String] = []
        for (label, marker) in expected where !marker.isEmpty && text.range(of: marker, options: .caseInsensitive) != nil {
            labels.append(label)
        }
        return labels.sorted()
    }

    /// Across all of an element's text attributes (value, title, description): the length to report
    /// (the first non-empty one) and every marker label found in any of them. The strings are not kept.
    public static func inspect(_ texts: [String?], expected: [String: String]) -> (length: Int?, matched: [String]) {
        let present = texts.compactMap(\.self).filter { !$0.isEmpty }
        let matched = Set(present.flatMap { labels(in: $0, expected: expected) })
        return (present.first?.count, matched.sorted())
    }
}

/// Finding and describing notification banners in an accessibility tree.
public enum Banners {
    /// macOS marks notification banners and alerts with subroles starting with this
    /// (seen up to macOS 15; `ax-probe tree` confirms it on the target Mac).
    public static let subrolePrefix = "AXNotificationCenter"

    /// Banner nodes under `root`, outermost first; a banner's own children are not searched again.
    public static func find(in root: NodeSnapshot, prefix: String = subrolePrefix) -> [NodeSnapshot] {
        if isBanner(root, prefix: prefix) {
            return [root]
        }
        return root.children.flatMap { find(in: $0, prefix: prefix) }
    }

    public static func isBanner(_ node: NodeSnapshot, prefix: String = subrolePrefix) -> Bool {
        node.subrole?.hasPrefix(prefix) ?? false
    }

    public static func summarize(_ banner: NodeSnapshot) -> BannerSummary {
        var summary = BannerSummary(subrole: banner.subrole, textLengths: [], buttons: 0, images: 0, found: [])
        visit(banner) { node in
            summary.found.formUnion(node.matched)
            switch node.role {
            case "AXButton":
                summary.buttons += 1 // a button's label is UI ("Close"), not notification text
            case "AXStaticText", "AXTextField", "AXTextArea":
                summary.textLengths.append(node.textLength ?? 0)
            default:
                if node.role == "AXImage" {
                    summary.images += 1
                }
                if let length = node.textLength {
                    summary.textLengths.append(length) // e.g. a banner group exposing its text as a description
                }
            }
        }
        return summary
    }

    /// One indented line per element: role, subrole, identifier length, text length, markers found.
    /// Never text.
    public static func describe(_ node: NodeSnapshot, maxDepth: Int = 12) -> [String] {
        var lines: [String] = []
        describe(node, depth: 0, maxDepth: maxDepth, into: &lines)
        return lines
    }

    private static func describe(_ node: NodeSnapshot, depth: Int, maxDepth: Int, into lines: inout [String]) {
        var line = String(repeating: "  ", count: depth) + (node.role ?? "?")
        if let subrole = node.subrole {
            line += "/" + subrole
        }
        if let length = node.identifierLength {
            line += " id=\(length)ch"
        }
        if let length = node.textLength {
            line += " text=\(length)ch"
        }
        if !node.matched.isEmpty {
            line += " matches=" + node.matched.joined(separator: ",")
        }
        if !node.children.isEmpty {
            line += " (\(node.children.count) children)"
        }
        lines.append(line)
        guard depth < maxDepth else {
            return
        }
        for child in node.children {
            describe(child, depth: depth + 1, maxDepth: maxDepth, into: &lines)
        }
    }

    private static func visit(_ node: NodeSnapshot, _ body: (NodeSnapshot) -> Void) {
        body(node)
        for child in node.children {
            visit(child, body)
        }
    }
}
