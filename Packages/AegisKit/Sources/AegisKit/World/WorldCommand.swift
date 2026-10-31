import Foundation

/// What the owner asked of the World view (#265, ADR-0024): a God's Eye View tool and its arguments, or opening
/// and closing the view. Parsed only from the owner's own words; never from collected content. Places the
/// owner names are public place names; their own places ("my house", "home") aren't put on the globe yet, and
/// camera and licence-plate layers are never asked for (DESIGN.md › World view).
public enum WorldCommand: Sendable, Equatable {
    case open
    case close
    case tool(name: String, arguments: WorldValue)
    /// "Show my trips": the owner's upcoming calendar places, pinned from coordinates on the Mac.
    case myTrips
    /// "Show my flight": a flight number from the owner's calendar, followed live.
    case myFlight
    /// "Set my home here": where the Mac is now becomes home, kept on the Mac.
    case setHome
    /// "Show my home": a pin at home, on the local globe only.
    case myHome
    /// One of God's Eye View's own page actions (zoom, tilt, style, layers, follow…), run in the globe itself.
    case action(name: String, arguments: WorldValue, said: String)
    /// "What about Sydney?": the last World question again, for another place.
    case retarget(place: String)
    /// "How's the air?", "any volcano alerts?", "any weather warnings?", "any aurora tonight?", "any disasters near me?":
    /// public data about home, no globe needed.
    case alerts(WorldAlerts.Kind)
    /// "What's happening in the world?": world headlines pinned at the countries they name (#116).
    case headlines
    /// Something the World view won't do, and what to say instead.
    case declined(String)

    /// `worldOpen`: "show me Tokyo" is a World command only while the globe is showing.
    /// `lastPlace`: the place of the last World question, while the conversation is about the globe; it makes
    /// "ships there" and "what about Sydney?" follow-ups.
    public static func parse(
        _ text: String, worldOpen: Bool, homeCity: String? = nil, lastPlace: String? = nil
    ) -> WorldCommand? {
        var line = cleaned(text)
        guard !line.isEmpty, line.count <= 160 else { return nil }
        if let fixed = fixedCommand(line) ?? alertCommand(line) {
            return fixed
        }
        if let lastPlace {
            if let place = capture(#"^(?:and |so )?(?:what|how) about (?:in |over |near )?(.+)$|^and (?:in |over |near )?(.+)$"#, line)
                ?? capture(#"^and (?:in |over |near )?(.+)$"#, line)
            {
                return onPlace(place) { _ in .retarget(place: place) }
            }
            line = line.replacingOccurrences(
                of: #"\b(?:over |near |around |in )?there\b"#,
                with: "near " + lastPlace,
                options: .regularExpression
            )
        }
        if worldOpen || line.range(of: #"\b(?:globe|world view|map)\b"#, options: .regularExpression) != nil,
           let action = pageAction(line.replacingOccurrences(
               of: #"\s+on the (?:globe|map|world view)$"#,
               with: "",
               options: .regularExpression
           ))
        {
            return action
        }
        return dataCommand(line) ?? skyOrPlaceCommand(line, worldOpen: worldOpen, homeCity: homeCity)
    }

    /// Flights, ships, earthquakes and fires.
    private static func dataCommand(_ line: String) -> WorldCommand? {
        if let place = capture(
            #"^(?:(?:show|find|are there|any|how many|what)(?: me)?(?: (?:any|the|all))? )?(military )?"#
                + #"(?:flights|planes|aircraft|jets)(?: (?:are|flying))?(?: (?:over|near|around|above|in|at)) (.+)$"#,
            line,
            group: 2
        ) {
            let military = capture(
                #"^(?:(?:show|find|are there|any|how many|what)(?: me)?(?: (?:any|the|all))? )?(military )"#,
                line,
                group: 1
            ) != nil
            return onPlace(place) { area in
                var arguments: [String: WorldValue] = ["area": area, "limit": .number(25)]
                if military {
                    arguments["military"] = .bool(true)
                }
                return .tool(name: "aircraft_in_area", arguments: .object(arguments))
            }
        }
        if let place = capture(#"(?:ships|boats|vessels)(?: (?:near|around|off|in|at)) (.+)$"#, line) {
            return onPlace(place) { .tool(name: "vessels_in_area", arguments: .object(["area": $0, "limit": .number(25)])) }
        }
        if line.range(of: #"\bearthquakes?\b"#, options: .regularExpression) != nil {
            guard let place = capture(#"earthquakes?(?: (?:near|in|around|off)) (.+)$"#, line) else {
                return .tool(name: "get_earthquakes", arguments: .object(["limit": .number(10)]))
            }
            return onPlace(place) { .tool(name: "get_earthquakes", arguments: .object(["area": $0, "limit": .number(10)])) }
        }
        if let place = capture(#"(?:bush ?fires?|wildfires?|fires)(?: (?:near|in|around)) (.+)$"#, line) {
            return onPlace(place) { .tool(name: "get_active_fires", arguments: .object(["area": $0, "limit": .number(25)])) }
        }
        return nil
    }

    /// The ISS and satellites, cyclones, weather, launches and moving the globe.
    private static func skyOrPlaceCommand(_ line: String, worldOpen: Bool, homeCity: String?) -> WorldCommand? {
        if line.range(of: #"\b(?:iss|international space station|space station)\b"#, options: .regularExpression) != nil {
            let named = capture(#"(?:iss|space station)(?: pass)?(?: (?:over|from|in|at|above)) (.+)$"#, line)
            guard let spot = named ?? homeCity else {
                return .declined("From where? Try “next ISS pass over Brisbane”.")
            }
            return onPlace(spot) { area in
                .tool(name: "next_satellite_pass", arguments: .object(["location": Self.location(from: area)]))
            }
        }
        if let place = capture(#"satellites(?: (?:over|above|overhead in|in)) (.+)$"#, line) {
            return onPlace(place) { area in
                .tool(name: "satellites_overhead", arguments: .object(["location": Self.location(from: area), "limit": .number(25)]))
            }
        }
        if line.range(of: #"\b(?:cyclones?|hurricanes?|typhoons?|tropical storms?)\b"#, options: .regularExpression) != nil {
            return .tool(name: "get_cyclones", arguments: .object([:]))
        }
        if let (kind, place) = weather(line) {
            return onPlace(place) { .tool(name: "get_weather_map", arguments: .object(["map": .string(kind), "area": $0])) }
        }
        if line.range(of: #"\b(?:rocket )?launch(?:es)?\b"#, options: .regularExpression) != nil,
           line.range(of: #"\b(?:recent|latest|last|any|show)\b"#, options: .regularExpression) != nil
        {
            return .tool(name: "get_recent_launches", arguments: .object(["limit": .number(5)]))
        }
        let fly = #"^(?:fly (?:me )?to|take me to|go to|zoom (?:in )?(?:to|on|in on)|show (?:me )?(.+) on the (?:globe|map|world))\s*(.*)$"#
        if let place = capture(fly, line, group: 2).flatMap({ $0.isEmpty ? nil : $0 }) ?? capture(fly, line, group: 1) {
            return onPlace(place) { .tool(name: "show_in_gods_eye_view", arguments: .object(["area": $0])) }
        }
        if worldOpen, let place = capture(#"^show(?: me)? (.+)$"#, line) {
            return onPlace(place) { .tool(name: "show_in_gods_eye_view", arguments: .object(["area": $0])) }
        }
        return nil
    }

    /// Air quality, eruptions, space weather, disasters and weather warnings, for home only: another named place is
    /// declined, not answered for home.
    private static func alertCommand(_ line: String) -> WorldCommand? {
        let air = #"\b(?:air quality|aqi|air pollution|smoke haze|bushfire smoke)\b|\b(?:is|how'?s|how is) the air\b|"#
            + #"\bis it (?:smoky|smokey|hazy)\b"#
        // Not "flights over Aurora": the city.
        let space = #"(?<!\b(?:over|near|in|around|to|at|from) )\b(?:auroras?|southern lights|northern lights)\b|"#
            + #"\b(?:space weather|geomagnetic|solar storms?|kp index)\b"#
        let disaster = #"\b(?:disasters?|catastrophes?|gdacs)\b"#
        let volcano = #"\b(?:volcan(?:o|oes|ic)|eruptions?|erupting|ash clouds?)\b"#
        // A volcano question is about now, not how volcanoes work.
        let current = #"\b(?:any|alerts?|warnings?|erupting|eruptions?|active|latest|recent|news|near|nearby|around|happening|today|now)\b"#
        let warning = #"\b(?:weather|storms?|thunderstorms?|floods?|flooding|fire|heat ?waves?|wind|cyclones?|bom|bureau)\b.*"#
            + #"\b(?:warnings?|alerts?|watch(?:es)?)\b|\bsevere weather\b|^(?:are there )?any warnings\b"#
        let kind: WorldAlerts.Kind
        if line.range(of: air, options: .regularExpression) != nil {
            kind = .air
        } else if line.range(of: volcano, options: .regularExpression) != nil, line.range(of: current, options: .regularExpression) != nil {
            kind = .volcanoes
        } else if line.range(of: space, options: .regularExpression) != nil {
            kind = .space
        } else if line.range(of: disaster, options: .regularExpression) != nil,
                  line.range(of: current, options: .regularExpression) != nil
        {
            kind = .disasters
        } else if line.range(of: warning, options: .regularExpression) != nil {
            kind = .warnings
        } else {
            return nil
        }
        let here = #"^(?:me|us|here|home|my (?:home|house|place|area|region)|where i live|area|region|moment|today|tonight|tomorrow|now|"#
            + #"this (?:week|area|morning|afternoon|evening))$"#
        if let place = capture(#"^.*\b(?:in|at|for|near|around|over|across) (?:the )?([a-z][a-z' -]*)$"#, line),
           place.range(of: here, options: .regularExpression) == nil
        {
            let only = switch kind {
            case .air: "the air at home"
            case .volcanoes: "for eruptions around home"
            case .warnings: "the Bureau of Meteorology's warnings for home"
            case .space: "space weather and aurora from home"
            case .disasters: "for disasters around home"
            }
            return .declined("I can only check \(only) for now.")
        }
        return .alerts(kind)
    }

    /// Commands with a fixed form: open, close, trips, home, flight and the headlines.
    private static func fixedCommand(_ line: String) -> WorldCommand? {
        let forms: [(String, WorldCommand)] = [
            (
                #"^(?:open|show|start)(?: me)? (?:the )?(?:world(?: view)?|globe|god'?s eye(?: view)?)$|^(?:world view|god'?s eye view)$"#,
                .open
            ),
            (#"^(?:close|hide|stop)(?: the)? (?:world(?: view)?|globe|god'?s eye(?: view)?)$"#, .close),
            (
                #"^(?:(?:show|put|pin)(?: me)? my (?:trips?|travels?|plans|places|calendar|events|appointments)"#
                    + #"(?: on the (?:globe|map|world))?|where am i (?:going|travell?ing|flying)(?: next| this week)?)$"#,
                .myTrips
            ),
            (
                #"^(?:set|save|mark|make)(?: my)? (?:home|house)(?: (?:as|to))? (?:here|this (?:place|location|spot))$|"#
                    + #"^(?:this is|i'm at|i am at) (?:my )?home(?: now)?$"#,
                .setHome
            ),
            (#"^(?:show(?: me)?|where(?:'s| is)|find|fly (?:me )?to|take me) (?:my )?home(?: on the (?:globe|map|world))?$"#, .myHome),
            (
                #"^(?:(?:show|find|track|follow|where(?:'s| is))(?: me)? my (?:next )?(?:flight|plane)|"#
                    + #"is my (?:flight|plane) (?:in the air|flying|airborne))$"#,
                .myFlight
            ),
            (
                #"^(?:(?:show|give|read|tell|get)(?: me)? )?(?:the )?(?:latest |top |today'?s )?(?:world |international |global )?"#
                    + #"(?:news|headlines|news headlines)(?: (?:on the (?:globe|map)|(?:from )?around the world|today))?$|"#
                    + #"^what'?s (?:happening|going on) (?:in|around) the world(?: today| right now| now)?$|"#
                    + #"^what'?s the (?:latest )?(?:world )?news$"#,
                .headlines
            ),
        ]
        return forms.first { line.range(of: $0.0, options: .regularExpression) != nil }?.1
    }

    /// The stand-in for "near home": the app swaps it for home's rounded coordinates.
    public static let nearHome: WorldValue = .object(["near_home": .bool(true)])

    /// Home's coordinates for a tool, rounded to 0.1° (about 10 km) with a 50 km radius for areas, so a query shows
    /// the region, never the house.
    public static func fillingHome(_ value: WorldValue, latitude: Double, longitude: Double) -> WorldValue {
        let lat = (latitude * 10).rounded() / 10, lon = (longitude * 10).rounded() / 10
        switch value {
        case nearHome:
            return .object(["lat": .number(lat), "lon": .number(lon), "radius_km": .number(50)])
        case let .object(fields):
            return .object(fields.mapValues { field in
                // A satellite tool's `location` takes a point, not an area.
                if field == nearHome, fields["location"] == field {
                    return .object(["lat": .number(lat), "lon": .number(lon)])
                }
                return fillingHome(field, latitude: latitude, longitude: longitude)
            })
        case let .array(items):
            return .array(items.map { fillingHome($0, latitude: latitude, longitude: longitude) })
        default:
            return value
        }
    }

    /// Whether a command needs home filled in.
    public static func needsHome(_ value: WorldValue) -> Bool {
        switch value {
        case nearHome: true
        case let .object(fields): fields.values.contains(where: needsHome)
        case let .array(items): items.contains(where: needsHome)
        default: false
        }
    }

    // MARK: - Helpers

    static func onPlace(_ raw: String, _ make: (WorldValue) -> WorldCommand) -> WorldCommand {
        let name = raw.replacingOccurrences(of: #"^(?:the )"#, with: "", options: .regularExpression)
            .replacingOccurrences(
                of: #"\s+(?:right now|now|today|at the moment|on the (?:globe|map))$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespaces)
        // Home is filled in on the Mac, rounded to about 10 km before anything leaves it.
        if name.range(of: #"^(?:(?:my |our )?(?:home|house|place)|here|where i live)$"#, options: .regularExpression) != nil {
            return make(nearHome)
        }
        if name.isEmpty || name.range(of: #"\b(?:my|our|me|home|work|here|the office)\b"#, options: .regularExpression) != nil {
            return .declined("I can't put your own places on the globe yet. Name a city or region instead.")
        }
        return make(.object(["place": .string(String(name.prefix(200)))]))
    }

    private static func location(from area: WorldValue) -> WorldValue {
        area
    }

    private static func weather(_ line: String) -> (String, String)? {
        let pattern = #"^(?:show(?: me)? )?(?:the )?(rain radar|weather radar|rain|radar|weather|storms?|lightning|clouds|"#
            + #"satellite weather|cloud cover)(?: map)?(?: (?:over|near|in|around|for)) (.+)$"#
        guard let kind = capture(pattern, line, group: 1), let place = capture(pattern, line, group: 2) else { return nil }
        let map = switch kind {
        case "lightning", "storm", "storms": "lightning"
        case "clouds", "satellite weather", "cloud cover": "satellite"
        default: "radar"
        }
        return (map, place)
    }

    private static func cleaned(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"^\s*(?:(?:hey|ok|okay)\s+)?aegis[,!.:]?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:please |can you |could you |would you )+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s?!.]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #",?\s*please$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func capture(_ pattern: String, _ line: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges > group, let range = Range(match.range(at: group), in: line)
        else { return nil }
        let value = String(line[range]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

/// A JSON value for tool arguments (#265).
public enum WorldValue: Sendable, Hashable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([WorldValue])
    case object([String: WorldValue])

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([WorldValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: WorldValue].self))
        }
    }
}
