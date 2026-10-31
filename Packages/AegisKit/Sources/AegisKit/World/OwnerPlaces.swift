import Foundation

/// The owner's own places on the globe (#265): upcoming calendar events with coordinates from EventKit, and flight
/// numbers in their calendar. Built on the Mac; the pins go only to the local globe.
public enum OwnerPlaces {
    /// Pins for events with coordinates, soonest first (at most 24, God's Eye View's limit), and a camera that
    /// frames them; nil when none has coordinates.
    public static func tripsView(_ occurrences: [CalendarOccurrence], now: Date, calendar: Calendar) -> WorldValue? {
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = Locale.autoupdatingCurrent
        day.dateFormat = "EEE d MMM"
        let placed = occurrences.filter { $0.coordinate != nil && $0.end >= now && $0.status != .cancelled }
            .sorted { $0.start < $1.start }.prefix(24)
        guard !placed.isEmpty else { return nil }
        let pins: [WorldValue] = placed.compactMap { event in
            guard let point = event.coordinate else { return nil }
            let label = String((event.title.isEmpty ? "Event" : event.title).prefix(80)) + " · " + day.string(from: event.start)
            return .object([
                "type": .string("pin"), "latitude": .number(point.latitude), "longitude": .number(point.longitude),
                "label": .string(label), "color": .string("primary"),
            ])
        }
        let camera = camera(framing: placed.compactMap(\.coordinate).map { ($0.latitude, $0.longitude) })
        return .object(["camera": camera, "layers": .array([]), "annotations": .array(pins)])
    }

    /// A camera looking straight down on the middle of the points, high enough to show them all.
    static func camera(framing points: [(latitude: Double, longitude: Double)]) -> WorldValue {
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let span = max((lats.max() ?? 0) - (lats.min() ?? 0), (lons.max() ?? 0) - (lons.min() ?? 0))
        let altitude = min(max(span * 111_000 * 1.6, 60000), 15_000_000)
        return .object([
            "lat": .number(((lats.max() ?? 0) + (lats.min() ?? 0)) / 2), "lon": .number(((lons.max() ?? 0) + (lons.min() ?? 0)) / 2),
            "altitude_m": .number(altitude.rounded()), "heading_deg": .number(0), "pitch_deg": .number(-90),
        ])
    }

    /// The next flight in the calendar (from 12 hours ago to 3 days ahead): its ICAO callsign ("QFA520") for live
    /// tracking, its written number ("QF520") and when it is.
    public static func nextFlight(_ occurrences: [CalendarOccurrence], now: Date) -> (callsign: String, number: String, start: Date)? {
        occurrences.filter { $0.start >= now.addingTimeInterval(-12 * 3600) && $0.start <= now.addingTimeInterval(3 * 86400) }
            .sorted { $0.start < $1.start }
            .lazy.compactMap { event in
                (flight(in: event.title) ?? event.location.flatMap(flight)).map { ($0.callsign, $0.number, event.start) }
            }.first
    }

    /// A flight number in a title or location ("Flight to Sydney QF 520" → QFA520, QF520).
    public static func flight(in text: String) -> (callsign: String, number: String)? {
        let pattern = #"\b([A-Z]{2}|[A-Z][0-9]|[0-9][A-Z])\s?(\d{1,4})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let airline = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
                  let digits = Range(match.range(at: 2), in: text).map({ String(text[$0]) }),
                  let icao = airlines[airline]
            else { continue }
            return (icao + digits, airline + digits)
        }
        return nil
    }

    /// IATA airline codes to the ICAO prefixes used in callsigns: Australian and New Zealand carriers first, then
    /// the main international ones flying here.
    static let airlines: [String: String] = [
        "QF": "QFA", "VA": "VOZ", "JQ": "JST", "ZL": "RXA", "TT": "TGW", "QQ": "UTY", "NZ": "ANZ", "EK": "UAE",
        "SQ": "SIA", "CX": "CPA", "QR": "QTR", "EY": "ETD", "UA": "UAL", "AA": "AAL", "DL": "DAL", "BA": "BAW",
        "NH": "ANA", "JL": "JAL", "AC": "ACA", "LH": "DLH", "AF": "AFR", "KL": "KLM", "TK": "THY", "CA": "CCA",
        "MU": "CES", "CZ": "CSN", "MH": "MAS", "GA": "GIA", "TG": "THA", "VN": "HVN", "PR": "PAL", "FJ": "FJI",
        "NF": "AVN", "HA": "HAL", "AS": "ASA", "WN": "SWA", "B6": "JBU", "FR": "RYR", "U2": "EZY", "3K": "JSA",
        "5J": "CEB", "D7": "XAX", "AK": "AXM", "TR": "TGW", "OZ": "AAR", "KE": "KAL", "BR": "EVA", "CI": "CAL",
        "AI": "AIC", "LA": "LAN", "SA": "SAA",
    ]
}
