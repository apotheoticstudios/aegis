import Foundation

/// World headlines on the globe (#116, ADR-0024): BBC News World's and Al Jazeera's public RSS headlines, each pinned at
/// the country it names. The news layer is worldmonitor's and Crucix's idea, and matching headlines to the places they
/// name is OSIRIS's; none of their code is used. Only the feed requests go out. Headlines are collected content: shown and
/// read, never passed to the model or acted on.
public enum WorldNews {
    /// World news from two public broadcasters, fetched whole when the owner asks.
    public static let feeds = [
        URL(string: "https://feeds.bbci.co.uk/news/world/rss.xml")!, // privacy-guard: allow-network BBC World RSS, ADR-0024
        URL(string: "https://www.aljazeera.com/xml/rss/all.xml")!, // privacy-guard: allow-network Al Jazeera RSS, ADR-0024
    ]

    /// macOS's time zone table (public domain): a point for each country, with no geocoding lookup.
    public static let zoneTable = URL(fileURLWithPath: "/usr/share/zoneinfo/zone.tab")

    /// A headline and the country it names.
    public struct Pin: Sendable, Equatable {
        public let headline: String
        public let country: String
        public let latitude: Double
        public let longitude: Double
    }

    /// A feed's item titles in order, at most 200 characters each. Angle brackets are dropped: the globe shows them.
    public static func headlines(_ rss: Data) -> [String] {
        String(decoding: rss, as: UTF8.self).components(separatedBy: "<item").dropFirst().compactMap { item in
            guard let start = item.range(of: "<title>"),
                  let end = item.range(of: "</title>", range: start.upperBound ..< item.endIndex)
            else { return nil }
            var title = item[start.upperBound ..< end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if title.hasPrefix("<![CDATA["), title.hasSuffix("]]>") {
                title = String(title.dropFirst(9).dropLast(3))
            } else {
                title = WorldAlerts.unescaped(title)
            }
            title = title.replacingOccurrences(of: #"[<>]|\s+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : String(title.prefix(200))
        }
    }

    /// Each country's point: the table's first zone for it, or its capital's where the first is an outlying one.
    public static func countries(zoneTab: Data) -> [String: (latitude: Double, longitude: Double)] {
        let capitals = [
            "AU": "Australia/Sydney", "BR": "America/Sao_Paulo", "CA": "America/Toronto", "RU": "Europe/Moscow",
            "UA": "Europe/Kyiv", "UZ": "Asia/Tashkent",
        ]
        var points: [String: (latitude: Double, longitude: Double)] = [:]
        for line in String(decoding: zoneTab, as: UTF8.self).split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count >= 3, let point = coordinate(fields[1]) else { continue }
            if points[fields[0]] == nil || capitals[fields[0]] == fields[2] {
                points[fields[0]] = point
            }
        }
        return points
    }

    /// One pin per country, for the first headline that names it, in the order given; at most 24 (God's Eye View's limit).
    public static func pins(_ headlines: [String], countries: [String: (latitude: Double, longitude: Double)]) -> [Pin] {
        let english = Locale(identifier: "en_US")
        var names: [String: (code: String, name: String)] = [:]
        for code in countries.keys {
            guard let full = english.localizedString(forRegionCode: code) else { continue }
            // "Myanmar (Burma)" → "Myanmar"; "Congo - Kinshasa" only by its aliases.
            let name = full.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
            for alias in (name.contains(" - ") ? [] : [name]) + (aliases[code] ?? []) {
                names[alias] = (code, name.contains(" - ") ? aliases[code]?.first ?? name : name)
            }
        }
        // Longest first, so "North Korea" wins over "Korea"; case-sensitive, so "turkey" the bird isn't Türkiye.
        let alternatives = names.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        let pattern = #"(?<![\p{L}\p{N}])(?:"# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}])"#
        guard !alternatives.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var pinned: [Pin] = []
        for headline in headlines where pinned.count < 24 {
            guard let match = regex.firstMatch(in: headline, range: NSRange(headline.startIndex..., in: headline)),
                  let range = Range(match.range, in: headline), let found = names[String(headline[range])],
                  let point = countries[found.code], !pinned.contains(where: { $0.country == found.name })
            else { continue }
            pinned.append(Pin(headline: headline, country: found.name, latitude: point.latitude, longitude: point.longitude))
        }
        return pinned
    }

    /// The globe's view: each pin labelled with its headline, and a camera framing them.
    public static func view(_ pins: [Pin]) -> WorldValue {
        let annotations: [WorldValue] = pins.map { pin in
            .object([
                "type": .string("pin"), "latitude": .number(pin.latitude), "longitude": .number(pin.longitude),
                "label": .string(String(pin.headline.prefix(80))), "color": .string("amber"),
            ])
        }
        let camera = OwnerPlaces.camera(framing: pins.map { ($0.latitude, $0.longitude) })
        return .object(["camera": camera, "layers": .array([]), "annotations": .array(annotations)])
    }

    /// What Aegis says: how many headlines are on the globe, and the first five by country.
    public static func answer(_ pins: [Pin]) -> String {
        guard !pins.isEmpty else { return "None of the latest world headlines names a country I can pin." }
        let top = pins.prefix(5).map { pin in
            "\(pin.country): \(pin.headline)" + (pin.headline.last.map { ".!?".contains($0) } == true ? "" : ".")
        }
        let count = pins.count == 1 ? "Here's the latest world headline" : "Here are \(pins.count) world headlines"
        return count + " on the globe. " + top.joined(separator: " ")
    }

    /// What headlines call countries besides their English names: short forms, their people and capitals. The first
    /// alias names a country whose English name has a dash ("Congo - Kinshasa").
    static let aliases: [String: [String]] = [
        "US": ["US", "U.S.", "USA", "American", "Americans", "Washington"],
        "GB": ["UK", "Britain", "British", "Scotland", "Scottish", "Wales", "Welsh", "London"],
        "RU": ["Russian", "Russians", "Moscow", "Kremlin"],
        "UA": ["Ukrainian", "Ukrainians", "Kyiv"],
        "CN": ["Chinese", "Beijing"],
        "TW": ["Taiwanese", "Taipei"],
        "HK": ["Hong Kong"],
        "JP": ["Japanese", "Tokyo"],
        "KP": ["North Korean", "Pyongyang"],
        "KR": ["South Korean", "Seoul"],
        "IN": ["Indian", "Delhi"],
        "PK": ["Pakistani", "Islamabad"],
        "AF": ["Afghan", "Kabul"],
        "IR": ["Iranian", "Tehran"],
        "IQ": ["Iraqi", "Baghdad"],
        "SY": ["Syrian", "Damascus"],
        "LB": ["Lebanese", "Beirut"],
        "IL": ["Israeli", "Israelis", "Jerusalem"],
        "PS": ["Gaza", "West Bank", "Palestinian", "Palestinians"],
        "SA": ["Saudi", "Riyadh"],
        "YE": ["Yemeni", "Houthi", "Houthis"],
        "EG": ["Egyptian", "Cairo"],
        "SD": ["Sudanese", "Khartoum"],
        "SS": ["South Sudanese"],
        "ET": ["Ethiopian"],
        "SO": ["Somali"],
        "NG": ["Nigerian"],
        "ZA": ["South African"],
        "CD": ["DR Congo", "DRC", "Democratic Republic of Congo"],
        "CG": ["Congo-Brazzaville", "Republic of Congo"],
        "CI": ["Ivory Coast"],
        "TR": ["Turkey", "Turkish", "Ankara"],
        "FR": ["French", "Paris"],
        "DE": ["German", "Germans", "Berlin"],
        "IT": ["Italian", "Rome"],
        "ES": ["Spanish", "Madrid"],
        "PL": ["Polish", "Warsaw"],
        "CZ": ["Czech Republic"],
        "BA": ["Bosnia"],
        "MX": ["Mexican"],
        "BR": ["Brazilian"],
        "AR": ["Argentine", "Argentinian"],
        "VE": ["Venezuelan", "Caracas"],
        "CO": ["Colombian"],
        "CU": ["Cuban", "Havana"],
        "HT": ["Haitian"],
        "CA": ["Canadian", "Ottawa"],
        "AU": ["Australian", "Australians", "Canberra"],
        "NZ": ["New Zealander", "Wellington"],
        "MM": ["Burma"],
        "PH": ["Philippine", "Filipino", "Manila"],
        "ID": ["Indonesian", "Jakarta"],
        "VN": ["Vietnamese", "Hanoi"],
        "TH": ["Thai", "Bangkok"],
        "BD": ["Bangladeshi", "Dhaka"],
    ]

    /// An ISO 6709 point from the table: ±DDMM[SS]±DDDMM[SS].
    static func coordinate(_ text: String) -> (latitude: Double, longitude: Double)? {
        guard let split = text.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        func degrees(_ part: Substring, width: Int) -> Double? {
            let digits = part.dropFirst()
            guard part.first == "+" || part.first == "-", digits.count == width + 2 || digits.count == width + 4,
                  let whole = Double(digits.prefix(width)), let minutes = Double(digits.dropFirst(width).prefix(2))
            else { return nil }
            let seconds = Double(digits.dropFirst(width + 2)) ?? 0
            return (part.first == "-" ? -1 : 1) * (whole + minutes / 60 + seconds / 3600)
        }
        guard let latitude = degrees(text[..<split], width: 2), let longitude = degrees(text[split...], width: 3) else { return nil }
        return (latitude, longitude)
    }
}
