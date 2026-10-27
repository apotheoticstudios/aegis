import Foundation

// x and y follow the requested public rectangle contract.
// swiftlint:disable identifier_name
/// A rectangle in display points, with a top-left origin and y increasing downwards.
public struct WindowArea: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    /// Creates a rectangle without depending on platform graphics types.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// swiftlint:enable identifier_name

/// A window's destination within a display's visible area.
public enum WindowZone: String, Sendable, CaseIterable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centreThird, rightThird, leftTwoThirds, rightTwoThirds
    case centre, full

    /// Returns equal-sized grid cells with `gap` points at the outer edges and between neighbours.
    /// Two-thirds zones span two third-width cells and their intervening gap. `centre` is 60% of
    /// the area's width and 70% of its height, centred; `full` fills the area inside the edge gap.
    /// Negative gaps become zero; gaps and centred dimensions shrink to fit very small areas.
    public func frame(in area: WindowArea, gap: Double = 8) -> WindowArea {
        let spacing = max(0, gap)
        if self == .centre {
            let width = min(max(0, area.width * 0.6), max(0, area.width - 2 * spacing))
            let height = min(max(0, area.height * 0.7), max(0, area.height - 2 * spacing))
            return WindowArea(
                x: area.x + (area.width - width) / 2,
                y: area.y + (area.height - height) / 2,
                width: width,
                height: height
            )
        }
        func axis(_ origin: Double, _ length: Double, _ parts: Int, _ index: Int, _ span: Int) -> (Double, Double) {
            let gap = min(spacing, max(0, length) / Double(parts + 1))
            let cell = max(0, (length - gap * Double(parts + 1)) / Double(parts))
            return (origin + gap + Double(index) * (cell + gap), Double(span) * cell + Double(span - 1) * gap)
        }
        let span = self == .leftTwoThirds || self == .rightTwoThirds ? 2 : 1
        let horizontal = axis(area.x, area.width, horizontalGrid.parts, horizontalGrid.index, span)
        let vertical = axis(area.y, area.height, verticalGrid.parts, verticalGrid.index, 1)
        return WindowArea(x: horizontal.0, y: vertical.0, width: horizontal.1, height: vertical.1)
    }

    private var horizontalGrid: (parts: Int, index: Int) {
        switch self {
        case .left, .topLeft, .bottomLeft: (2, 0)
        case .right, .topRight, .bottomRight: (2, 1)
        case .leftThird, .leftTwoThirds: (3, 0)
        case .centreThird, .rightTwoThirds: (3, 1)
        case .rightThird: (3, 2)
        default: (1, 0)
        }
    }

    private var verticalGrid: (parts: Int, index: Int) {
        switch self {
        case .top, .topLeft, .topRight: (2, 0)
        case .bottom, .bottomLeft, .bottomRight: (2, 1)
        default: (1, 0)
        }
    }
}

/// An app name from the owner's request and the zone requested for it.
public struct WindowPlacement: Sendable, Hashable {
    /// The owner's spelling and capitalisation, with surrounding whitespace removed.
    public let app: String
    public let zone: WindowZone

    /// Creates a placement; resolving the name to a running app belongs to the macOS caller.
    public init(app: String, zone: WindowZone) {
        self.app = app.trimmingCharacters(in: .whitespacesAndNewlines)
        self.zone = zone
    }
}

/// Parses window layouts exclusively from the owner's own words. Callers must never pass collected content.
/// Parsing only describes placements; it performs no actions or app discovery.
public enum WindowLayoutCommand {
    /// Matches a whole layout request, preserving app names. Returns nil for incomplete requests,
    /// repeated zones, more than four placements, or app names longer than 40 characters.
    public static func parse(_ text: String) -> [WindowPlacement]? {
        let line = cleaned(text)
        guard !line.isEmpty, line.rangeOfCharacter(from: .newlines) == nil else { return nil }
        if let app = capture(#"^focus\s+on\s+(.+)$|^(?:maximise|maximize)\s+(.+)$"#, line) {
            return placement(app, .full).map { [$0] }
        }
        if let app = capture(#"^(?:centre|center)\s+(.+)$"#, line) {
            return placement(app, .centre).map { [$0] }
        }
        let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
        if let prefix = line.range(of: #"^split\s+"#, options: options) {
            let apps = String(line[prefix.upperBound...])
            guard let separator = apps.range(of: #"\s+and\s+"#, options: options),
                  let left = placement(String(apps[..<separator.lowerBound]), .left),
                  let right = placement(String(apps[separator.upperBound...]), .right),
                  right.app.range(of: #"\s+and\s+"#, options: options) == nil
            else { return nil }
            return [left, right]
        }
        return zonedPlacements(line)
    }

    private static func zonedPlacements(_ line: String) -> [WindowPlacement]? {
        let zones: [(String, WindowZone)] = [
            ("left two thirds", .leftTwoThirds), ("right two thirds", .rightTwoThirds),
            ("left third", .leftThird), ("centre third", .centreThird), ("center third", .centreThird),
            ("right third", .rightThird), ("top left", .topLeft), ("top right", .topRight),
            ("bottom left", .bottomLeft), ("bottom right", .bottomRight), ("full screen", .full),
            ("left", .left), ("right", .right), ("top", .top), ("bottom", .bottom),
            ("centre", .centre), ("center", .centre), ("middle", .centre),
        ]
        let alternatives = zones.map { $0.0.replacingOccurrences(of: " ", with: #"\s+"#) }.joined(separator: "|")
        let pattern = #"^(?:put\s+)?(.+?)\s+(?:(?:on|in)\s+(?:the\s+)?)?("# + alternatives + #")(?=\s|,|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        var remainder = line
        var result: [WindowPlacement] = []
        while !remainder.isEmpty {
            guard result.count < 4,
                  let match = regex.firstMatch(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)),
                  let appRange = Range(match.range(at: 1), in: remainder),
                  let zoneRange = Range(match.range(at: 2), in: remainder),
                  let wholeRange = Range(match.range, in: remainder)
            else { return nil }
            let zoneName = remainder[zoneRange].lowercased()
                .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
            guard let zone = zones.first(where: { $0.0 == zoneName })?.1,
                  !result.contains(where: { $0.zone == zone }),
                  let item = placement(String(remainder[appRange]), zone)
            else { return nil }
            result.append(item)
            remainder = String(remainder[wholeRange.upperBound...])
            if remainder.isEmpty {
                break
            }
            // A separator must be followed by another complete placement, never trailing words or a comma.
            let separator = #"^(?:\s*,\s*(?:and\s+)?|\s+and\s+|\s+)(?=\S)"#
            guard let range = remainder.range(of: separator, options: [.regularExpression, .caseInsensitive]) else { return nil }
            remainder.removeSubrange(range)
        }
        return result.isEmpty ? nil : result
    }

    private static func placement(_ raw: String, _ zone: WindowZone) -> WindowPlacement? {
        let app = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty, app.count <= 40,
              app.range(of: #"^[\p{L}\p{N}][\p{L}\p{N}\p{M} .&'’()+_-]*$"#, options: .regularExpression) != nil
        else { return nil }
        return WindowPlacement(app: app, zone: zone)
    }

    private static func cleaned(_ text: String) -> String {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Match without lowercasing the source string, so Unicode app names retain their original spelling.
        for pattern in [
            #"^(?:(?:hey|ok|okay)\s+)?[a-z]+[,!.:]\s*"#,
            #"^(?:(?:hey|ok|okay)\s+)?aegis\b\s*"#,
            #"^(?:please\s+)+"#,
            #"[\s?!.]+$"#,
            #",?\s+please$"#,
        ] {
            line = line.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capture(_ pattern: String, _ line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return nil }
        for group in 1 ..< match.numberOfRanges {
            if let range = Range(match.range(at: group), in: line) {
                return String(line[range])
            }
        }
        return nil
    }
}
