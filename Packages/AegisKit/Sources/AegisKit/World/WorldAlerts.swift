import Foundation

/// Air quality, eruptions and Australian weather warnings around home (ADR-0024), for the brief and the owner's
/// questions. Only the air-quality request carries a place: home rounded to 0.1° (about 10 km). The eruption list and
/// the Bureau of Meteorology's warning files are fetched whole and matched against home on the Mac. This type builds
/// the requests and reads the answers; the panel fetches them.
public enum WorldAlerts {
    /// What the owner asked about.
    public enum Kind: String, Sendable, CaseIterable {
        case air, volcanoes, warnings
    }

    // MARK: - Air quality

    /// Today's air at home, rounded to 0.1°, from Open-Meteo's air-quality model (free, no key).
    public static func airURL(latitude: Double, longitude: Double) -> URL? {
        let lat = (latitude * 10).rounded() / 10, lon = (longitude * 10).rounded() / 10
        let base = "https://air-quality-api.open-meteo.com/v1/air-quality" // privacy-guard: allow-network rounded home air, ADR-0024
        return URL(string: base + "?latitude=\(lat)&longitude=\(lon)&current=us_aqi&hourly=us_aqi&forecast_days=1&timezone=auto")
    }

    /// "Air at home: good (AQI 39)." and, when a worse band is coming later today, when. Nil when it can't be read.
    public static func air(_ data: Data, now: Date, locale: Locale = .autoupdatingCurrent) -> String? {
        struct Answer: Decodable {
            struct Current: Decodable {
                let usAqi: Double?
            }

            struct Hourly: Decodable {
                let time: [String]
                let usAqi: [Double?]
            }

            let timezone: String?
            let current: Current?
            let hourly: Hourly?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let answer = try? decoder.decode(Answer.self, from: data), let index = answer.current?.usAqi else { return nil }
        let current = airBand(index)
        var line = "Air at home: \(current.words) (AQI \(Int(index.rounded())))."
        let zone = answer.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = zone
        parse.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let later = answer.hourly.map { hourly in
            zip(hourly.time, hourly.usAqi).compactMap { time, value -> (Date, Double)? in
                guard let value, let date = parse.date(from: time), date > now else { return nil }
                return (date, value)
            }
        } ?? []
        if let (time, worst) = later.max(by: { $0.1 < $1.1 }), airBand(worst).band > current.band {
            let speak = DateFormatter()
            speak.locale = locale
            speak.timeZone = zone
            speak.dateFormat = "h a"
            let words = airBand(worst).words
            line += " " + words.prefix(1).uppercased() + words.dropFirst()
                + " around \(speak.string(from: time).lowercased()) (AQI \(Int(worst.rounded())))."
        }
        return line
    }

    /// The US AQI's bands, the scale Open-Meteo gives worldwide.
    static func airBand(_ index: Double) -> (band: Int, words: String) {
        let bands = ["good", "moderate", "unhealthy for sensitive people", "unhealthy", "very unhealthy"]
        let tops = [50.0, 100, 150, 200, 300]
        let band = tops.firstIndex { index.rounded() <= $0 } ?? bands.count
        return (band, band < bands.count ? bands[band] : "hazardous")
    }

    // MARK: - Volcanoes

    /// Eruptions within this distance of home count as the region: from eastern Australia, Indonesia to New Zealand.
    public static let volcanoRegionKm = 5000.0

    /// Significant eruptions worldwide over the last 30 days, from GDACS (the UN and EU's disaster alerts; free, no
    /// key). Nothing about home is sent.
    public static func volcanoesURL(now: Date) -> URL? {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        let from = day.string(from: now.addingTimeInterval(-30 * 86400)), to = day.string(from: now)
        let base = "https://www.gdacs.org/gdacsapi/api/events/geteventlist/SEARCH" // privacy-guard: allow-network GDACS, ADR-0024
        return URL(string: base + "?eventlist=VO&fromDate=\(from)&toDate=\(to)")
    }

    /// "Kanlaon, Philippines: an orange-alert eruption on 10 October, 4,800 km from home." for each eruption in the
    /// region within the last `days`, nearest first. Empty data (GDACS answers 204 when there are none) is no eruptions;
    /// nil when the answer can't be read.
    public static func volcanoes(
        _ data: Data, latitude: Double, longitude: Double, now: Date, days: Double, locale: Locale = .autoupdatingCurrent
    ) -> [String]? {
        struct List: Decodable {
            struct Feature: Decodable {
                struct Geometry: Decodable {
                    let coordinates: [Double]
                }

                struct Properties: Decodable {
                    let eventname: String?
                    let country: String?
                    let alertlevel: String?
                    let todate: String?
                }

                let geometry: Geometry?
                let properties: Properties
            }

            let features: [Feature]
        }
        if data.isEmpty {
            return []
        }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { return nil }
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = TimeZone(identifier: "UTC")
        parse.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let speak = DateFormatter()
        speak.locale = locale
        speak.dateFormat = "d MMMM"
        let found = list.features.compactMap { feature -> (Double, String)? in
            guard let point = feature.geometry?.coordinates, point.count >= 2, let name = feature.properties.eventname,
                  let date = feature.properties.todate.flatMap(parse.date(from:)), now.timeIntervalSince(date) <= days * 86400
            else { return nil }
            let distance = kilometres(latitude, longitude, point[1], point[0])
            guard distance <= volcanoRegionKm else { return nil }
            let kind = feature.properties.alertlevel.map { $0.lowercased() + "-alert eruption" } ?? "eruption"
            let article = "aeiou".contains(kind.prefix(1)) ? "an" : "a"
            let country = feature.properties.country.map { ", " + $0 } ?? ""
            let away = (Int((distance / 100).rounded()) * 100).formatted(.number.locale(locale))
            return (distance, "\(name)\(country): \(article) \(kind) on \(speak.string(from: date)), \(away) km from home.")
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    // MARK: - Australian weather warnings

    /// Home in the Bureau of Meteorology's terms: the state warning files to read and the districts and river gauges
    /// that cover home.
    public struct BureauArea: Sendable, Equatable {
        /// Warning file prefixes, such as "IDQ" for Queensland.
        public let prefixes: Set<String>
        /// Public warning and fire weather districts, and river gauges, such as "QLD_PW015" and "QLD_RS020".
        public let codes: Set<String>
    }

    /// The Bureau's public FTP folder of current warnings, one CAP file each, named by state. It's the Bureau's channel
    /// for automated use; its website and app data forbid it. Nothing about home is sent.
    public static let bureauWarnings = bureau("gen/fwo/")
    /// The Bureau's forecast towns, with their warning districts; fetched once a month.
    public static let bureauTowns = bureau("home/adfd/spatial/IDM00013.dbf")
    /// The Bureau's river gauges; fetched once a month.
    public static let bureauGauges = bureau("home/adfd/spatial/IDM00018.dbf")

    private static func bureau(_ path: String) -> URL {
        URL(string: "ftp://ftp.bom.gov.au/anon/" + path)! // privacy-guard: allow-network Bureau public FTP, ADR-0024
    }

    static let statePrefixes = ["NSW": "IDN", "ACT": "IDN", "VIC": "IDV", "QLD": "IDQ", "SA": "IDS", "WA": "IDW", "TAS": "IDT", "NT": "IDD"]

    /// Home's districts: the nearest forecast town's, and those of towns within 15 km in case home is near a district's
    /// edge, plus river gauges within 25 km for flood warnings. Nil when no town is within 100 km: home isn't in
    /// Australia, or the tables can't be read.
    public static func bureauArea(towns: Data, gauges: Data, latitude: Double, longitude: Double) -> BureauArea? {
        let places = dbf(towns).compactMap { row -> (Double, [String: String])? in
            guard let lat = row["LAT"].flatMap(Double.init), let lon = row["LON"].flatMap(Double.init) else { return nil }
            return (kilometres(latitude, longitude, lat, lon), row)
        }
        guard let nearest = places.min(by: { $0.0 < $1.0 }), nearest.0 <= 100 else { return nil }
        let near = places.filter { $0.0 <= 15 }.map(\.1) + [nearest.1]
        var codes = Set(near.flatMap { [$0["AAC_PW"], $0["AAC_FW"]] }.compactMap(\.self).filter { !$0.isEmpty })
        for gauge in dbf(gauges) {
            if let code = gauge["AAC"], !code.isEmpty, let lat = gauge["LAT"].flatMap(Double.init),
               let lon = gauge["LON"].flatMap(Double.init), kilometres(latitude, longitude, lat, lon) <= 25
            {
                codes.insert(code)
            }
        }
        return BureauArea(prefixes: Set(near.compactMap { statePrefixes[$0["STATE_CODE"] ?? ""] }), codes: codes)
    }

    /// The home state's warning files in the folder's listing. Names are checked before they go into a request.
    public static func bureauFiles(listing: String, area: BureauArea) -> [String] {
        listing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { name in
            name.range(of: #"^ID[A-Z]\d{5}\.cap\.xml$"#, options: .regularExpression) != nil
                && area.prefixes.contains(String(name.prefix(3)))
        }
    }

    /// The headlines of a warning file's current parts that cover home: "Severe Thunderstorm Warning for …".
    /// Cancellations, tests and expired parts are left out. The text is shown and read, never acted on.
    public static func bureauWarnings(_ cap: Data, area: BureauArea, now: Date) -> [String] {
        let text = String(decoding: cap, as: UTF8.self)
        guard field("status", in: text) == "Actual", field("msgType", in: text) != "Cancel" else { return [] }
        let iso = ISO8601DateFormatter()
        let parts = text.components(separatedBy: "<info>").dropFirst()
        let headlines = parts.compactMap { info -> String? in
            guard let headline = field("headline", in: info).map(unescaped), !headline.lowercased().hasPrefix("cancellation"),
                  (field("expires", in: info).flatMap(iso.date(from:)) ?? .distantFuture) > now,
                  !area.codes.isDisjoint(with: values(in: info))
            else { return nil }
            return String(headline.prefix(200))
        }
        return headlines.reduce(into: []) {
            if !$0.contains($1) {
                $0.append($1)
            }
        }
    }

    // MARK: - Helpers

    /// The rows of a dBase table (the Bureau's map files), each field trimmed. Empty when the bytes aren't one.
    static func dbf(_ data: Data) -> [[String: String]] {
        let bytes = [UInt8](data)
        guard bytes.count > 32 else { return [] }
        func number(_ at: Int, _ size: Int) -> Int {
            (0 ..< size).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) }
        }
        let count = number(4, 4), header = number(8, 2), length = number(10, 2)
        var fields: [(name: String, width: Int)] = []
        var at = 32
        while at + 32 <= bytes.count, bytes[at] != 0x0D {
            fields.append((String(decoding: bytes[at ..< at + 11].prefix { $0 != 0 }, as: UTF8.self), Int(bytes[at + 16])))
            at += 32
        }
        guard length > 0, fields.reduce(1, { $0 + $1.width }) <= length, header + count * length <= bytes.count else { return [] }
        return (0 ..< count).compactMap { row in
            var offset = header + row * length
            guard bytes[offset] != 0x2A else { return nil } // "*": a deleted row
            offset += 1
            var values: [String: String] = [:]
            for field in fields {
                let raw = String(bytes: bytes[offset ..< offset + field.width], encoding: .isoLatin1) ?? ""
                values[field.name] = raw.trimmingCharacters(in: .whitespaces)
                offset += field.width
            }
            return values
        }
    }

    /// Great-circle distance in kilometres.
    static func kilometres(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let rad = Double.pi / 180
        let half = pow(sin((lat2 - lat1) * rad / 2), 2) + cos(lat1 * rad) * cos(lat2 * rad) * pow(sin((lon2 - lon1) * rad / 2), 2)
        return 12742 * asin(min(1, half.squareRoot()))
    }

    private static func field(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name)>"), let end = text.range(of: "</\(name)>", range: start.upperBound ..< text.endIndex)
        else { return nil }
        return text[start.upperBound ..< end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The area codes in a CAP part: <value>QLD_PW015</value>.
    private static func values(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"<value>\s*([A-Z]{2,3}_[A-Z]{2}\d{3})\s*</value>"#) else { return [] }
        return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    private static func unescaped(_ text: String) -> String {
        [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")].reduce(text) {
            $0.replacingOccurrences(of: $1.0, with: $1.1)
        }
    }
}
