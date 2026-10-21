import Foundation

/// The globe's own controls and follow-ups (#272).
public extension WorldCommand {
    /// God's Eye View's own controls, by voice: zoom, tilt, spin, style, map, layers, following and cockpit view.
    internal static func pageAction(_ line: String) -> WorldCommand? {
        if let direction = capture(#"^zoom (in|out)(?: (?:a (?:bit|little)|a lot|more))?$"#, line) {
            let amount = line.hasSuffix("a lot") ? "lot" : line.contains("a bit") || line.contains("a little") ? "little" : "medium"
            return .action(
                name: "adjust_camera_zoom",
                arguments: .object(["direction": .string(direction), "amount": .string(amount)]),
                said: "Zooming \(direction)."
            )
        }
        if line.range(
            of: #"^(?:zoom out to |show )?(?:the )?(?:whole (?:world|globe|planet)|full globe|entire globe)$"#,
            options: .regularExpression
        ) != nil {
            return .action(name: "zoom_to_globe", arguments: .object([:]), said: "Here's the whole world.")
        }
        if let direction = capture(#"^tilt (up|down)$"#, line) {
            return .action(
                name: "move_camera",
                arguments: .object(["motion": .string("tilt"), "direction": .string(direction)]),
                said: "Tilting \(direction)."
            )
        }
        if let direction = capture(#"^(?:rotate|spin|turn|pan) (left|right)$"#, line) {
            return .action(
                name: "move_camera",
                arguments: .object(["motion": .string("rotate"), "direction": .string(direction)]),
                said: "Turning \(direction)."
            )
        }
        if line.range(of: #"^(?:orbit|circle|fly around)(?: (?:it|here|this))?$"#, options: .regularExpression) != nil {
            return .action(
                name: "move_camera",
                arguments: .object(["motion": .string("orbit"), "direction": .string("right")]),
                said: "Orbiting."
            )
        }
        if line.range(of: #"^stop(?: (?:moving|spinning|turning|orbiting|the camera))?$"#, options: .regularExpression) != nil {
            return .action(name: "move_camera", arguments: .object(["motion": .string("stop")]), said: "Holding still.")
        }
        if line.range(of: #"^stop (?:following|tracking)(?: (?:it|that|the plane|the flight))?$"#, options: .regularExpression) != nil {
            return .action(name: "stop_tracking", arguments: .object([:]), said: "Stopped following.")
        }
        if let callsign = capture(#"^(?:follow|track) (?:flight |the flight |plane )?([a-z]{2,3} ?\d{1,4}|[a-z0-9]{2}-?[a-z]{3})$"#, line) {
            let code = callsign.uppercased().replacingOccurrences(of: " ", with: "")
            let icao = OwnerPlaces.flight(in: code).map(\.callsign) ?? code
            return .action(name: "track_entity", arguments: .object(["query": .string(icao)]), said: "Following \(code).")
        }
        if let action = capture(#"^(enter|exit|leave) (?:the )?cockpit(?: view)?$|^cockpit view$"#, line) ??
            (line == "cockpit view" ? "enter" : nil)
        {
            let mode = action == "enter" ? "enter" : "exit"
            return .action(
                name: "control_cockpit",
                arguments: .object(["action": .string(mode)]),
                said: mode == "enter" ? "Cockpit view." : "Back outside."
            )
        }
        if line.range(of: #"^clear (?:the )?(?:globe|map|pins|marks|annotations|everything)$"#, options: .regularExpression) != nil {
            return .action(name: "clear_annotations", arguments: .object([:]), said: "Cleared.")
        }
        return styleOrLayer(line)
    }

    static func styleOrLayer(_ line: String) -> WorldCommand? {
        let styles: [(String, String)] = [
            ("night vision", "surveillance"), ("surveillance", "surveillance"), ("thermal", "thermal"), ("heat vision", "thermal"),
            ("normal", "normal"), ("retro", "retro"), ("noir", "noir"), ("black and white", "noir"), ("anime", "anime"), ("snow", "snow"),
        ]
        if let name = capture(
            #"^(?:switch to |use |turn on |go )?(night vision|surveillance|thermal|heat vision|normal|retro|noir|black and white|anime|snow)(?: mode| view| style| vision)?$"#,
            line
        ),
            let style = styles.first(where: { $0.0 == name })?.1
        {
            return .action(name: "set_visual_style", arguments: .object(["style": .string(style)]), said: "Switched to \(name).")
        }
        let maps: [(String, String, String)] = [
            (
                #"^(?:switch to |show |use )?(?:3d|three d|photoreal(?:istic)?)(?: (?:view|cities|map|buildings))?$"#,
                "photoreal",
                "3D view."
            ),
            (#"^(?:switch to |show |use )?satellite (?:imagery|map|view|photos)$"#, "esri-imagery", "Satellite imagery."),
            (#"^(?:switch to |show |use )?(?:the )?(?:street map|road map|map view|plain map)$"#, "osm", "Street map."),
        ]
        if let map = maps.first(where: { line.range(of: $0.0, options: .regularExpression) != nil }) {
            return .action(name: "set_map_stack", arguments: .object(["stack": .string(map.1)]), said: map.2)
        }
        let pattern = #"^(?:(turn|switch) (on|off) (?:the )?(.+?)|(show|hide) (?:the |all )?(.+?)|(.+?) (on|off))(?: layer)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return nil }
        let part = { (index: Int) in Range(match.range(at: index), in: line).map { String(line[$0]) } ?? "" }
        let words = [part(3), part(5), part(6)].first { !$0.isEmpty } ?? ""
        let on = part(2) == "on" || part(4) == "show" || part(7) == "on"
        guard let layer = layers.first(where: { words.range(of: "^(?:" + $0.0 + ")$", options: .regularExpression) != nil })
        else { return nil }
        return .action(
            name: "set_layer_visibility", arguments: .object(["layerId": .string(layer.1), "enabled": .bool(on)]),
            said: (on ? "Showing " : "Hiding ") + layer.2 + "."
        )
    }

    /// Spoken layer names and God's Eye View's ids. No cameras or licence-plate readers.
    static let layers: [(String, String, String)] = [
        ("flights|planes|aircraft|air traffic", "flights", "flights"), (
            "military(?: aircraft| flights| planes)?",
            "military",
            "military aircraft"
        ),
        ("ships|boats|vessels|shipping", "ais-live-vessels", "ships"), ("satellites", "satellites", "satellites"),
        ("(?:rocket )?launches", "rocket-launches", "launches"), ("earthquakes|quakes", "earthquakes", "earthquakes"),
        ("fires|bushfires|wildfires", "local-firms", "fires"), ("cyclones|hurricanes|storms", "weather-cyclones", "cyclones"),
        ("(?:rain )?radar|rain", "weather-radar", "the rain radar"), ("clouds|cloud cover", "weather-satellite", "the clouds"),
        ("lightning", "weather-lightning", "lightning"), ("wind", "wind", "the wind"), ("air quality", "air-quality", "air quality"),
        ("traffic", "traffic", "traffic"), ("transit|trains|buses|public transport", "transit", "public transport"),
        ("(?:submarine |undersea )?cables", "telegeography-submarine-cables", "undersea cables"), (
            "radio(?: stations)?",
            "radio",
            "radio stations"
        ),
    ]

    /// The last World question for another place ("what about Sydney?"); nil when it had no place.
    func retargeted(to place: String) -> WorldCommand? {
        guard case let .tool(name, arguments) = self, case let .object(fields) = arguments else { return nil }
        var changed = fields
        for key in ["area", "location"] where fields[key] != nil {
            changed[key] = .object(["place": .string(place)])
        }
        return changed == fields ? nil : .tool(name: name, arguments: .object(changed))
    }

    /// The place a World question was about, for follow-ups.
    var place: String? {
        guard case let .tool(_, .object(fields)) = self else { return nil }
        for key in ["area", "location"] {
            if case let .object(spot)? = fields[key], case let .string(name)? = spot["place"] {
                return name
            }
        }
        return nil
    }
}
