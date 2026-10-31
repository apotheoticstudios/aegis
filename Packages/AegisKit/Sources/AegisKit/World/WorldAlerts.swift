import Foundation

/// Air quality, eruptions and other disasters, space weather and Australian weather warnings around home (ADR-0024),
/// for the brief and the owner's questions. Only the air-quality request carries a place: home rounded to 0.1° (about
/// 10 km). The disaster list, the Kp forecast and the Bureau of Meteorology's warning files are fetched whole and matched
/// against home on the Mac. This type builds the requests and reads the answers; the panel fetches them.
public enum WorldAlerts {
    /// What the owner asked about.
    public enum Kind: String, Sendable, CaseIterable {
        case air, volcanoes, warnings, space, disasters
    }

    /// A regional alert for the brief. `key` names the event and its level, so an escalation counts as new (#115).
    public struct Alert: Sendable, Equatable {
        public let key: String
        public let text: String
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

    // MARK: - Eruptions and other disasters

    /// Alerts within this distance of home count as the region: from eastern Australia, Indonesia to New Zealand.
    public static let regionKm = 5000.0

    /// GDACS's significant alerts worldwide over the last 30 days (the UN and EU's disaster alerts; free, no key):
    /// earthquakes, cyclones, floods, eruptions, wildfires and droughts. Nothing about home is sent.
    public static func disastersURL(now: Date) -> URL? {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        let from = day.string(from: now.addingTimeInterval(-30 * 86400)), to = day.string(from: now)
        let base = "https://www.gdacs.org/gdacsapi/api/events/geteventlist/SEARCH" // privacy-guard: allow-network GDACS, ADR-0024
        return URL(string: base + "?eventlist=EQ;TC;FL;VO;WF;DR&fromDate=\(from)&toDate=\(to)")
    }

    /// "Kanlaon, Philippines: an orange-alert eruption on 10 October, 4,800 km from home." for each alert in the region
    /// within the last `days`, nearest first; `only` keeps one GDACS type ("VO" for eruptions). Empty data (GDACS answers
    /// 204 when there are none) is no alerts; nil when the answer can't be read.
    public static func disasters(
        _ data: Data, only: String? = nil, latitude: Double, longitude: Double, now: Date, days: Double,
        locale: Locale = .autoupdatingCurrent
    ) -> [Alert]? {
        struct List: Decodable {
            struct Feature: Decodable {
                struct Geometry: Decodable {
                    let coordinates: [Double]
                }

                struct Properties: Decodable {
                    let eventtype: String?
                    let eventid: Int?
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
        let kinds = ["EQ": "earthquake", "TC": "tropical cyclone", "FL": "flood", "VO": "eruption", "WF": "wildfire", "DR": "drought"]
        let found = list.features.compactMap { feature -> (Double, Alert)? in
            let event = feature.properties
            guard let type = event.eventtype, let kind = kinds[type], only == nil || only == type,
                  let point = feature.geometry?.coordinates, point.count >= 2,
                  let date = event.todate.flatMap(parse.date(from:)), now.timeIntervalSince(date) <= days * 86400
            else { return nil }
            let distance = kilometres(latitude, longitude, point[1], point[0])
            let countries = (event.country ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let place = countries.count > 2 ? "\(countries[0]), \(countries[1]) and \(countries.count - 2) more" : countries
                .joined(separator: " and ")
            // Volcanoes and cyclones have names; the rest are known by their place.
            let title = [type == "VO" || type == "TC" ? event.eventname ?? "" : "", place].filter { !$0.isEmpty }.joined(separator: ", ")
            guard distance <= regionKm, !title.isEmpty else { return nil }
            let level = event.alertlevel.map { $0.lowercased() + "-alert " + kind } ?? kind
            let article = "aeiou".contains(level.prefix(1)) ? "an" : "a"
            let away = (Int((distance / 100).rounded()) * 100).formatted(.number.locale(locale))
            let key = "\(type)-\(event.eventid.map(String.init) ?? title)-\(event.alertlevel ?? "")"
            return (distance, Alert(key: key, text: "\(title): \(article) \(level) on \(speak.string(from: date)), \(away) km from home."))
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    // MARK: - Space weather

    /// NOAA's planetary Kp index, observed and forecast in 3-hour steps (public, no key). Nothing about home is sent: home's
    /// geomagnetic latitude is worked out here.
    public static let spaceURL = URL(
        string: "https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json" // privacy-guard: allow-network NOAA, ADR-0024
    )!

    /// The answer to "any aurora tonight?" for the step under way and the next 24 hours, and an alert for the brief when a
    /// storm may make aurora visible from home or is strong (G3+). Nil when the answer can't be read.
    public static func space(
        _ data: Data, latitude: Double, longitude: Double, now: Date, timeZone: TimeZone = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> (answer: String, alert: Alert?)? {
        struct Step: Decodable {
            let timeTag: String
            let kp: Double
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let steps = try? decoder.decode([Step].self, from: data) else { return nil }
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = TimeZone(identifier: "UTC")
        parse.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let ahead = steps.compactMap { step -> (start: Date, step: Step)? in
            guard let start = parse.date(from: step.timeTag), start > now.addingTimeInterval(-3 * 3600),
                  start <= now.addingTimeInterval(86400)
            else { return nil }
            return (start, step)
        }
        guard let peak = ahead.max(by: { $0.step.kp < $1.step.kp }) else { return nil }
        let kp = peak.step.kp
        let scale = min(5, Int(kp.rounded()) - 4) // NOAA's G scale: Kp 5 is G1, Kp 9 is G5.
        var answer: String
        if scale >= 1 {
            let words = ["minor", "moderate", "strong", "severe", "extreme"][scale - 1]
            let speak = DateFormatter()
            speak.locale = locale
            speak.timeZone = timeZone
            speak.dateFormat = "h a"
            let when = peak.start <= now ? "is under way" : "is forecast around \(speak.string(from: peak.start).lowercased())"
            answer = "\(words == "extreme" ? "An" : "A") \(words) geomagnetic storm (G\(scale)) \(when)."
        } else {
            answer = "No geomagnetic storm is forecast for the next day (Kp \(Int(kp.rounded())) at most)."
        }
        // shortcut: a rule of thumb (the auroral oval's edge by Kp, plus about 8° seen towards the horizon); NOAA's OVATION
        // model is the upgrade if it misleads.
        let visible = abs(geomagneticLatitude(latitude, longitude)) >= 58.5 - 2 * kp
        answer += visible
            ? " Aurora may be visible from home looking \(latitude < 0 ? "south" : "north"), away from city lights."
            : " Aurora isn't likely to be seen from home."
        let alert = scale >= 1 && (visible || scale >= 3) ? Alert(key: "space-G\(scale)-" + peak.step.timeTag.prefix(10), text: answer) :
            nil
        return (answer, alert)
    }

    /// Geomagnetic latitude on a dipole whose north pole is at 80.8° N, 72.6° W (IGRF, 2025).
    static func geomagneticLatitude(_ latitude: Double, _ longitude: Double) -> Double {
        let rad = Double.pi / 180, poleLat = 80.8 * rad, poleLon = -72.6 * rad
        let lat = latitude * rad, lon = longitude * rad
        return asin(sin(lat) * sin(poleLat) + cos(lat) * cos(poleLat) * cos(lon - poleLon)) / rad
    }

    // MARK: - What's new

    /// Crucix's sweep delta, re-implemented (#115): a regional alert stays in the brief for 12 hours after it first appears,
    /// or escalates (a new key), then drops out. Returns the alerts to show and the first-seen times, kept 30 days.
    public static func fresh(_ alerts: [Alert], firstSeen: [String: Date], now: Date) -> (alerts: [Alert], firstSeen: [String: Date]) {
        var seen = firstSeen.filter { now.timeIntervalSince($0.value) < 30 * 86400 }
        let shown = alerts.filter { alert in
            let first = seen[alert.key] ?? now
            seen[alert.key] = first
            return now.timeIntervalSince(first) < 12 * 3600
        }
        return (shown, seen)
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
