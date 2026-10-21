import Foundation

/// The World view's lines in the brief (#265, ADR-0024): today's weather at home and the status of today's flight,
/// from public data. Only home's rounded coordinates (about 10 km) and a flight's callsign are sent; this type
/// builds the requests and reads the answers, the panel fetches them.
public enum WorldBrief {
    /// Today's forecast for home, rounded to 0.1°, from Open-Meteo (free, no key).
    public static func weatherURL(latitude: Double, longitude: Double) -> URL? {
        let lat = (latitude * 10).rounded() / 10, lon = (longitude * 10).rounded() / 10
        let base = "https://api.open-meteo.com/v1/forecast" // privacy-guard: allow-network rounded home forecast, ADR-0024
        return URL(string: base + "?latitude=\(lat)&longitude=\(lon)&daily=temperature2mMax,temperature2mMin,"
            + "precipitationProbabilityMax,weatherCode&hourly=precipitation_probability&forecast_days=1&timezone=auto")
    }

    /// "Weather at home: 18 to 27°. Rain likely from 3 pm (70%)." Nil when the answer can't be read.
    public static func weather(_ data: Data, now: Date, locale: Locale = .autoupdatingCurrent) -> String? {
        struct Forecast: Decodable {
            struct Daily: Decodable {
                let temperature2mMax: [Double?]
                let temperature2mMin: [Double?]
                let precipitationProbabilityMax: [Double?]?
                let weatherCode: [Int?]?

                enum CodingKeys: String, CodingKey {
                    case temperature2mMax = "temperature_2m_max", temperature2mMin = "temperature_2m_min"
                    case precipitationProbabilityMax = "precipitation_probability_max", weatherCode = "weather_code"
                }
            }

            struct Hourly: Decodable {
                let time: [String]
                let precipitationProbability: [Double?]

                enum CodingKeys: String, CodingKey {
                    case time, precipitationProbability = "precipitation_probability"
                }
            }

            let timezone: String?
            let daily: Daily
            let hourly: Hourly?
        }
        guard let forecast = try? JSONDecoder().decode(Forecast.self, from: data),
              let high = forecast.daily.temperature2mMax.first ?? nil,
              let low = forecast.daily.temperature2mMin.first ?? nil
        else { return nil }
        var line = "Weather at home: \(Int(low.rounded())) to \(Int(high.rounded()))°."
        let code = forecast.daily.weatherCode?.first ?? nil
        let chance = Int(((forecast.daily.precipitationProbabilityMax?.first ?? nil) ?? 0).rounded())
        let zone = forecast.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = zone
        parse.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let speak = DateFormatter()
        speak.locale = locale
        speak.timeZone = zone
        speak.dateFormat = "h a"
        let wet = forecast.hourly.map { hourly in
            zip(hourly.time, hourly.precipitationProbability).first { time, probability in
                (probability ?? 0) >= 50 && (parse.date(from: time).map { $0 >= now.addingTimeInterval(-3600) } ?? false)
            }
        } ?? nil
        if let code, (95 ... 99).contains(code) {
            line += " Storms are possible (\(chance)%)."
        } else if let (time, probability) = wet, let start = parse.date(from: time) {
            line += " Rain likely from \(speak.string(from: start).lowercased()) (\(Int((probability ?? 0).rounded()))%)."
        } else if chance >= 30 {
            line += " A chance of showers (\(chance)%)."
        } else {
            line += " No rain expected."
        }
        return line
    }

    /// A flight's live position by callsign, from adsb.lol (public ADS-B, no key).
    public static func flightURL(callsign: String) -> URL? {
        let clean = callsign.uppercased().filter { $0.isLetter || $0.isNumber }
        guard (3 ... 8).contains(clean.count) else { return nil }
        return URL(string: "https://api.adsb.lol/v2/callsign/" + clean) // privacy-guard: allow-network flight status by callsign, ADR-0024
    }

    /// "QF520 is in the air at 34,000 ft." or when it's due, from the tracker's answer.
    public static func flight(
        _ data: Data?, number: String, start: Date, now: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent
    ) -> String {
        struct Answer: Decodable {
            struct Aircraft: Decodable {
                let altBaro: AltitudeValue?
                let gs: Double?
            }

            let ac: [Aircraft]?
        }
        enum AltitudeValue: Decodable {
            case feet(Double), ground
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let feet = try? container.decode(Double.self) {
                    self = .feet(feet)
                } else {
                    self = .ground
                }
            }
        }
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = locale
        time.dateFormat = "h:mm a"
        let due = time.string(from: start).lowercased()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let data, let answer = try? decoder.decode(Answer.self, from: data), let plane = answer.ac?.first {
            if case let .feet(feet)? = plane.altBaro, feet > 500 {
                let rounded = Int((feet / 1000).rounded()) * 1000
                return "\(number) is in the air at \(rounded.formatted(.number.locale(locale))) ft."
            }
            return "\(number) is on the ground with its transponder on (due \(due))."
        }
        return start > now ? "\(number) is due at \(due) and isn't in the air yet." : "\(number) (due \(due)) isn't showing in the air."
    }
}
