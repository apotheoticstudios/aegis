import AppKit
import SwiftUI
import Synchronization

/// Character art, the design system's signature: pictures built from the density ramp ` .:-=+*#%@`, ported from its
/// generators. Every shape moves at 12 frames a second, a deliberately terminal-like rate, only while the panel shows.
enum HUDAscii {
    static let ramp = Array(" .:-=+*#%@")
    /// A banner cell's width over its height (Share Tech Mono, 0.04 em tracking, line height 1).
    static let cellAspect = 0.58
    /// An art cell's width over its height: the 0.54 em advance less 0.04 em tracking, so two columns per row are square.
    static let artAspect = 0.5

    /// The shapes the screens use, each with its meaning: radar scanning, an eye watching, a helix syncing, a wave
    /// for voice, and an anatomical heart beating for the system's health.
    enum Shape {
        case radar, eye, helix, wave, anatomy
        /// Slow-winding spiral arms: quiet. A turning wireframe cube with a pulsing core: an addon module.
        case galaxy, cube
        /// Aegis's shield, a hex-plated sphere rippling with impacts: AegisShell engaging.
        case shield
        /// Sand running down to the next event; a fingerprint scanning while details are hidden.
        case hourglass, fingerprint
        /// Bands that stretch to any shape: an equaliser (the brief, voice), a wireframe floor rolling toward you.
        case spectrum, horizon
        /// A sphere with a light circling it.
        case orb
        /// A targeting reticle: spokes turn and the inner ring breathes.
        case reticle
        /// A heart beating with a double pulse every 1.2 s.
        case heart
        /// A globe spinning on its axis.
        case globe
        /// Flight down a ringed tunnel: rings rush outward, rails twist and the far end glows.
        case tunnel
        /// A banded planet with a ring passing behind and in front, and an orbiting moon.
        case planet
        /// A heavy cloud with slanting rain and a lightning strike every 4.5 s.
        case storm
        /// A bright sun disc with long and short rays turning slowly and breathing.
        case sun
        /// A crescent moon with craters, earthshine and twinkling stars.
        case moon
        /// A processor: package, pins, traces carrying pulses and cores lighting up on the die.
        case chip
        /// Falling code: each column has its own speed and length, with the head brightest.
        case rain
        /// A skyline at night: towers, windows going on and off, and a blinking mast.
        case city
        /// A black hole: shadow, photon ring and a turning accretion disc bent over the top.
        case blackhole
        /// Home in plan view: lit rooms, an open garage door with a pulsing alarm, and a locked front door.
        case floorplan
        /// A lit torus tilting back and forth while bands run round it, shaded by a fixed light.
        case torus
        /// A hypercube turning through the fourth dimension: inner and outer cubes trade places.
        case tesseract
        /// An atom: three orbits at 60°, electrons with short trails and a busy nucleus.
        case atom
    }

    /// The art as lines, `time` seconds in (0 is the still frame); `grit` breaks the shading up like hand-made art.
    static func art(_ shape: Shape, cols: Int, rows: Int, seed: Double = 1, grit: Double = 0.35, time: Double = 0) -> [String] {
        let aspect = Double(cols) * artAspect / Double(rows)
        let live = (time * 8).rounded(.down)
        let grid = Grid.cached(cols: cols, rows: rows, seed: seed, grit: grit)
        let heart = shape == .anatomy ? grid.heart : []
        var line = [UInt8](repeating: 0, count: cols)
        return (0 ..< rows).map { row in
            for col in 0 ..< cols {
                let cell = row * cols + col
                var level = heart.isEmpty ? density(
                    shape,
                    grid.across[col],
                    grid.down[row],
                    time,
                    aspect,
                    column: col,
                    row: row,
                    rows: rows
                )
                    : HUDAnatomy.density(heart[cell], time)
                if level > 0 {
                    level += grid.grain[cell]
                    if grid.dropped[cell] {
                        level = 0
                    }
                    if time > 0 {
                        level += (hash(Double(col), Double(row), seed + live) - 0.5) * 0.08
                    }
                }
                line[col] = rampBytes[Int(min(max(level, 0), 0.999) * Double(rampBytes.count))]
            }
            // Trailing spaces dropped, as the design's generators do.
            let end = (line.lastIndex { $0 != 0x20 } ?? -1) + 1
            return String(decoding: line[..<end], as: UTF8.self)
        }
    }

    private static let rampBytes = Array(" .:-=+*#%@".utf8)

    /// What never changes for one piece of art, worked out once instead of every frame: each cell's place and its
    /// hand-made grain and gaps.
    private struct Grid: Sendable {
        let across: [Double]
        let down: [Double]
        let grain: [Double]
        let dropped: [Bool]
        /// The heart's unbeating parts per cell, worked out the first time a heart is drawn on this grid.
        var heart: [HUDAnatomy.Fixed] {
            Self.hearts.withLock { hearts in
                let key = Key(cols: across.count, rows: down.count, seed: 0, grit: 0)
                if let cells = hearts[key] {
                    return cells
                }
                let cells = down.flatMap { down in across.map { HUDAnatomy.Fixed($0, down) } }
                hearts[key] = cells
                return cells
            }
        }

        private struct Key: Hashable {
            let cols: Int, rows: Int, seed: Double, grit: Double
        }

        private static let cache = Mutex<[Key: Grid]>([:])
        private static let hearts = Mutex<[Key: [HUDAnatomy.Fixed]]>([:])

        static func cached(cols: Int, rows: Int, seed: Double, grit: Double) -> Grid {
            let key = Key(cols: cols, rows: rows, seed: seed, grit: grit)
            if let grid = cache.withLock({ $0[key] }) {
                return grid
            }
            let grid = Grid(cols: cols, rows: rows, seed: seed, grit: grit)
            cache.withLock { grids in
                if grids.count >= 64 {
                    grids.removeAll()
                }
                grids[key] = grid
            }
            return grid
        }

        private init(cols: Int, rows: Int, seed: Double, grit: Double) {
            across = (0 ..< cols).map { (Double($0) + 0.5) / Double(cols) * 2 - 1 }
            down = (0 ..< rows).map { (Double($0) + 0.5) / Double(rows) * 2 - 1 }
            var grain: [Double] = []
            var dropped: [Bool] = []
            grain.reserveCapacity(cols * rows)
            dropped.reserveCapacity(cols * rows)
            for row in 0 ..< rows {
                for col in 0 ..< cols {
                    grain.append((HUDAscii.hash(Double(col), Double(row), seed) - 0.5) * grit)
                    dropped.append(HUDAscii.hash(Double(row), Double(col), seed + 3) < grit * 0.18)
                }
            }
            self.grain = grain
            self.dropped = dropped
        }
    }

    static func hash(_ px: Double, _ py: Double, _ seed: Double) -> Double {
        let value = sin(px * 127.1 + py * 311.7 + seed * 74.7) * 43758.5453
        return value - value.rounded(.down)
    }

    /// How dense the shape is at (across, down) in -1...1 (down runs down), 0 to 1.
    /// Exhaustive dispatch keeps each shape's coordinate convention visible here.
    static func density( // swiftlint:disable:this cyclomatic_complexity
        _ shape: Shape, _ across: Double, _ down: Double, _ time: Double, _ aspect: Double,
        column: Int? = nil, row: Int = 0, rows: Int = 0
    ) -> Double {
        let fittedAcross = aspect > 1 ? across * aspect : across
        let fittedDown = aspect > 1 ? down : down / aspect
        return switch shape {
        case .radar: radar(across, down, time)
        case .eye: HUDEye.density(across, down, time, aspect)
        case .helix: helix(across, down, time)
        case .wave: wave(across, down, time)
        case .anatomy: HUDAnatomy.density(across, down, time)
        case .galaxy: galaxy(across, down, time)
        // The cube keeps its proportions in a wide footprint, centred.
        case .cube: HUDCube.density(aspect > 1 ? across * aspect : across, aspect > 1 ? down : down / aspect, time)
        case .shield: shield(aspect > 1 ? across * aspect : across, aspect > 1 ? down : down / aspect, time)
        case .hourglass: hourglass(aspect > 1 ? across * aspect : across, aspect > 1 ? down : down / aspect, time)
        case .fingerprint: fingerprint(aspect > 1 ? across * aspect : across, aspect > 1 ? down : down / aspect, time)
        // Strips stretch to their band, as the design's do.
        case .spectrum: spectrum(across, down, time)
        case .horizon: horizon(across, down, time)
        case .orb: orb(fittedAcross, fittedDown, time)
        case .reticle: reticle(fittedAcross, fittedDown, time)
        case .heart: heart(fittedAcross, fittedDown, time)
        case .globe: globe(fittedAcross, fittedDown, time)
        case .tunnel: tunnel(fittedAcross, fittedDown, time)
        case .planet: planet(fittedAcross, fittedDown, time)
        case .storm: storm(fittedAcross, fittedDown, time)
        case .sun: sun(fittedAcross, fittedDown, time)
        case .moon: moon(fittedAcross, fittedDown, time)
        case .chip: chip(fittedAcross, fittedDown, time)
        case .rain: rain(column: column, row: row, rows: rows, time: time)
        case .city: city(across, down, time)
        case .blackhole: blackhole(fittedAcross, fittedDown, time)
        case .floorplan: floorplan(across, down, time, aspect)
        case .torus: torus(fittedAcross, fittedDown, time)
        case .tesseract: tesseract(fittedAcross, fittedDown, time)
        case .atom: atom(fittedAcross, fittedDown, time)
        }
    }

    /// JavaScript's `%` made positive.
    static func wrap(_ value: Double) -> Double {
        let rest = value.truncatingRemainder(dividingBy: 1)
        return rest < 0 ? rest + 1 : rest
    }

    /// The top bulb empties, the pile grows, the stream falls; it turns over every 16 s.
    private static func hourglass(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let filled = (time + 5.5).truncatingRemainder(dividingBy: 16) / 16, height = abs(down), side = abs(across)
        if height > 0.92 {
            return side < 0.62 && height < 1 ? 0.95 : 0
        }
        let post = abs(side - 0.66) < 0.035 ? 0.4 : 0
        let wall = 0.06 + 0.5 * pow(height / 0.92, 1.15)
        if abs(side - wall) < 0.03 {
            return 0.85
        }
        guard side <= wall else { return post }
        let grain = hash((across * 40).rounded(.down), (down * 40).rounded(.down), 3) * 0.2
        if down < -0.04, down > -0.04 - 0.84 * (1 - filled).squareRoot() {
            return 0.55 + grain
        }
        let pile = 0.9 - 0.8 * filled.squareRoot() + side * 0.55
        if down > 0.04, down > pile {
            return 0.6 + grain
        }
        if side < 0.025, down > -0.04, down < pile, filled < 0.985 {
            return wrap(down * 14 - time * 10) < 0.6 ? 0.7 : 0.2
        }
        return 0.05
    }

    /// Whorled ridges in an oval; a scan line passes, lighting what it has read.
    private static func fingerprint(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let ovalAcross = across / 0.74, ovalDown = (down + 0.02) / 0.98
        guard ovalAcross * ovalAcross + ovalDown * ovalDown <= 1 else { return 0 }
        let angle = atan2(down + 0.12, across)
        let reach = (pow(across / 0.6, 2) + pow((down + 0.12) / 0.8, 2)).squareRoot() + 0.06 * sin(angle * 2 + 0.6)
            + 0.03 * sin(across * 5 + down * 3)
        let ridge = (reach * 6.5).truncatingRemainder(dividingBy: 1)
        if hash((reach * 6.5).rounded(.down), ((angle + 4) * 2.2).rounded(.down), 7) < 0.1 {
            return 0.05
        }
        guard ridge <= 0.45 else { return 0 }
        let scan = time > 0 ? ((time * 0.32).truncatingRemainder(dividingBy: 1.3) - 0.15) * 2.2 - 1.1 : 2
        let gap = down - scan
        return abs(gap) < 0.04 ? 1 : gap < 0 ? 0.8 : 0.3
    }

    /// Bars rise and fall; peak caps hang and drop.
    private static func spectrum(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let bars = 28.0, place = (across + 1) / 2 * bars, bar = place.rounded(.down), height = 1 - (down + 1) / 2
        guard place - bar <= 0.72 else { return 0 }
        let damping = 1 - abs(bar - bars * 0.38) / bars * 0.8
        func level(_ at: Double) -> Double {
            abs(sin(bar * 0.62 + at * 3.1) * sin(bar * 0.27 - at * 1.9 + 1.2))
        }
        let current = 0.12 + 0.82 * level(time) * damping, cap = 0.12 + 0.82 * max(level(time - 0.3), level(time)) * damping
        if abs(height - cap - 0.04) < 0.025 {
            return 0.9
        }
        return height < current ? 0.35 + 0.6 * (height / max(current, 0.01)) : 0
    }

    /// A wireframe floor rolling toward you, low mountains on the skyline and a striped setting sun.
    private static func horizon(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let skyline = -0.3
        if down > skyline {
            let below = down - skyline, depth = 0.5 / (below + 0.01)
            let along = wrap(depth * 1.6 - time * 1.4), lane = wrap(across * depth * 2.2)
            let rung = min(0.45, 0.03 * 1.6 * 0.5 / ((below + 0.01) * (below + 0.01))), rail = min(0.4, 0.012 * 2.2 * depth)
            if below < 0.025 {
                return 0.9
            }
            return along < rung || abs(lane - 0.5) < rail ? 0.2 + 0.7 * min(1, below * 2.4) : 0
        }
        let ridge = skyline - 0.1 * abs(sin(across * 2.7 + 0.4)) - 0.07 * abs(sin(across * 6.3)) - 0.03 * abs(sin(across * 15))
        if down > ridge {
            return abs(down - ridge) < 0.03 ? 0.7 : 0.05
        }
        let sun = ((across * 1.5) * (across * 1.5) + (down - skyline + 0.02) * (down - skyline + 0.02)).squareRoot()
        if sun < 0.5 {
            let rise = (skyline - down) / 0.5, stripe = (rise * 9 + time * 0.4).truncatingRemainder(dividingBy: 1)
            return rise > 0.45 || stripe < 1 - rise * 0.6 - 0.2 ? 0.45 + 0.5 * (1 - sun / 0.5) : 0
        }
        return hash((across * 60).rounded(.down), (down * 30).rounded(.down), 4) > 0.985 ? 0.3 : 0
    }

    /// The plates are a hex grid wrapped round the sphere; three impacts send ripples across them.
    private static func shield(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let squared = across * across + down * down
        guard squared <= 1 else { return 0 }
        let depth = (1 - squared).squareRoot(), lens = 1 / (depth + 0.55), root3 = 3.0.squareRoot()
        let px = across * lens * 3.1, py = down * lens * 3.1 + time * 0.12
        // Cube-rounding to the nearest hex, rounding halves up as the design's JavaScript does.
        let qx = px * 2 / root3, qy = py - px / root3
        var rx = (qx + 0.5).rounded(.down), ry = (qy + 0.5).rounded(.down)
        let rz = (-qx - qy + 0.5).rounded(.down)
        let dx = abs(rx - qx), dy = abs(ry - qy), dz = abs(rz + qx + qy)
        if dx > dy, dx > dz {
            rx = -ry - rz
        } else if dy > dz {
            ry = -rx - rz
        }
        let hx = abs(px - rx * root3 / 2), hy = abs(py - (ry + rx / 2))
        let edge = max(hx * 0.866 + hy * 0.5, hy) > 0.42
        var level = edge ? 0.3 + 0.45 * depth : 0.04 + 0.08 * depth
        var ripple = 0.0
        for (hitAcross, hitDown, phase) in [(0.35, -0.3, 0.0), (-0.45, 0.25, 1.1), (0.1, 0.5, 2.2)] where time > 0 {
            let age = (time + phase).truncatingRemainder(dividingBy: 3.3), reach = age * 0.75
            let distance = ((across - hitAcross) * (across - hitAcross) + (down - hitDown) * (down - hitDown)).squareRoot()
            if abs(distance - reach) < 0.08 {
                ripple = max(ripple, 1 - age / 3.3)
            }
            if age < 0.25, distance < 0.08 {
                ripple = 1
            }
        }
        if ripple > 0 {
            level = min(1, level + ripple * (edge ? 0.55 : 0.3))
        }
        return squared.squareRoot() > 0.94 ? max(level, 0.85) : level
    }

    /// The arms wind slowly.
    private static func galaxy(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let radius = (across * across + down * down * 2.2).squareRoot()
        guard radius <= 1.05 else { return 0 }
        let angle = atan2(down * 1.5, across) - time * 0.35
        let arms = 0.5 + 0.5 * cos(2 * angle - 6 * log(radius + 0.05))
        return min(max(exp(-radius * 2.4) * (1.3 + 0.15 * sin(time * 2)) + arms * (1 - radius) * 0.7, 0), 1)
    }

    /// The sweep turns; blips flare as it passes them.
    private static func radar(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let radius = (across * across + down * down).squareRoot()
        guard radius <= 1 else { return 0 }
        var level = [0.98, 0.66, 0.33].contains { abs(radius - $0) < 0.045 } ? 0.55 : 0
        if abs(across) < 0.03 || abs(down) < 0.055 {
            level = max(level, 0.35)
        }
        let sweep = -0.6 + time * 1.6
        let behind = { (px: Double, py: Double) in (sweep - atan2(py, px) + 40 * .pi).truncatingRemainder(dividingBy: 2 * .pi) }
        if behind(across, down) < 1.6 {
            level = max(level, 0.95 * (1 - behind(across, down) / 1.6))
        }
        for blip in [(0.32, -0.4), (-0.45, 0.2), (0.55, 0.35)] where abs(across - blip.0) < 0.05 && abs(down - blip.1) < 0.08 {
            level = max(level, 0.35 + 0.65 * max(0, 1 - behind(blip.0, blip.1) / 3))
        }
        return level
    }

    /// The strands rotate.
    private static func helix(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let phase = across * 6.5 + time * 2
        let strand = 0.7 * sin(phase)
        let front = cos(phase)
        var level = 0.0
        if abs(down - strand) < 0.2 {
            level = front > 0 ? 1 : 0.5
        }
        if abs(down + strand) < 0.2 {
            level = max(level, front < 0 ? 1 : 0.5)
        }
        if abs(sin(phase * 2.5)) < 0.3, down > -abs(strand), down < abs(strand) {
            level = max(level, 0.35)
        }
        return level
    }

    /// The waveform travels.
    private static func wave(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let crest = 0.35 * sin(across * 4.2 - time * 1.6) + 0.18 * sin(across * 9.1 + 1.3 + time * 2.3)
        let distance = down - crest
        if distance < -0.06 {
            return max(0, 0.3 - abs(distance) * 0.6) * (hash(across, down, 9 + (time * 6).rounded(.down)) > 0.7 ? 1 : 0)
        }
        return max(0, 1 - distance * 0.9)
    }
}

/// An addon module: a wireframe cube turning with a little perspective, its near edges brighter, a core pulsing inside.
private enum HUDCube {
    static func density(_ across: Double, _ down: Double, _ time: Double) -> Double {
        var best = 0.0
        for edge in edges(time) {
            let (start, end) = edge
            let dx = end.across - start.across
            let dy = end.down - start.down
            let span = max(dx * dx + dy * dy, 1e-6)
            let along = min(max(((across - start.across) * dx + (down - start.down) * dy) / span, 0), 1)
            let distance = hypot(start.across + dx * along - across, start.down + dy * along - down)
            let depth = (start.depth + (end.depth - start.depth) * along + 0.9) / 1.8
            let width = 0.06 + 0.05 * depth
            if distance < width {
                best = max(best, (1 - distance / width) * (0.4 + 0.6 * depth) + 0.15)
            }
        }
        let radius = hypot(across, down)
        let core = 0.2 + 0.05 * sin(time * 3.2)
        return radius < core ? max(best, 0.6 * (1 - radius / core) + 0.25) : best
    }

    private struct Point {
        let across: Double, down: Double, depth: Double
    }

    /// The twelve edges at `time`, projected.
    private static func edges(_ time: Double) -> [(Point, Point)] {
        let turn = 0.62 + time * 0.55
        let tilt = 0.5 + sin(time * 0.35) * 0.22
        let corners = (0 ..< 8).map { corner -> Point in
            let px = corner & 1 == 0 ? -0.5 : 0.5
            let py = corner & 2 == 0 ? -0.5 : 0.5
            let pz = corner & 4 == 0 ? -0.5 : 0.5
            let turnedX = px * cos(turn) + pz * sin(turn)
            let turnedZ = -px * sin(turn) + pz * cos(turn)
            let tiltedY = py * cos(tilt) - turnedZ * sin(tilt)
            let tiltedZ = py * sin(tilt) + turnedZ * cos(tilt)
            let scale = 2.1 / (2.6 - tiltedZ)
            return Point(across: turnedX * scale, down: tiltedY * scale, depth: tiltedZ)
        }
        var edges: [(Point, Point)] = []
        for first in 0 ..< 8 {
            for second in first + 1 ..< 8 where [1, 2, 4].contains(first ^ second) {
                edges.append((corners[first], corners[second]))
            }
        }
        return edges
    }
}

/// The Aegis emblem in characters, from the logo kit (Resources/Brand, 80 and 112 characters wide): a scan band
/// brightens it as it passes, a few characters flicker, and it resolves out of noise as it arrives.
struct HUDEmblemArt: View {
    /// Footprint cells across; the art is twice as many characters wide, as the design's emblem is.
    var cols = 56
    var tone = HUD.accent
    var label: String?
    @Environment(\.accessibilityReduceMotion) private var still
    @Environment(\.hudArrival) private var arrival

    var body: some View {
        let lines = Self.art(wide: cols * 2 >= 96)
        let width = lines.map(\.count).max() ?? 1
        let size: CGFloat = 6
        let moving = HUDPresence.shared.animating && !still
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !moving)) { context in
            let time = moving ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) : 0
            let scanned = time > 0 ? Self.scan(lines, time) : lines
            let shown = arrival.elapsed(context.date).map {
                HUDMotion.resolve(scanned, HUDMotion.progress($0, 0, 1.1), tick: Int($0 * 12))
            } ?? scanned
            HUDAsciiText(lines: shown, cols: width, size: size, tone: tone, aspect: HUDAscii.artAspect)
        }
        .accessibilityElement()
        .accessibilityHidden(label == nil)
        .accessibilityLabel(label ?? "")
        .accessibilityAddTraits(.isImage)
    }

    private static let wideArt = load("emblem-112")
    private static let narrowArt = load("emblem-80")

    static func art(wide: Bool) -> [String] {
        wide ? wideArt : narrowArt
    }

    private static func load(_ name: String) -> [String] {
        let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Brand")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return text.components(separatedBy: "\n").reversed().drop { $0.isEmpty }.reversed()
    }

    /// The band runs down the art every few seconds, lifting each character up the ramp; about one in thirty dims.
    static func scan(_ lines: [String], _ time: Double) -> [String] {
        let band = ((time * 0.45).truncatingRemainder(dividingBy: 1.4) - 0.2) * Double(lines.count)
        let live = (time * 10).rounded(.down)
        let ramp = HUDAscii.ramp
        return lines.enumerated().map { row, line in
            let lift = max(0, 1 - abs(Double(row) - band) / 2.2)
            return String(line.enumerated().map { col, character in
                guard var level = ramp.firstIndex(of: character), level > 0 else { return character }
                level = min(ramp.count - 1, level + Int((lift * 3).rounded()))
                if HUDAscii.hash(Double(col), Double(row), 1 + live) < 0.03 {
                    level = max(1, level - 2 - Int(HUDAscii.hash(Double(row), Double(col), live) * 3))
                }
                return ramp[level]
            })
        }
    }
}

/// A round eye: full elliptical lids, a circular ringed iris with slow-turning spokes, a catchlight and lash ticks;
/// its gaze drifts and it blinks every 7 seconds.
private enum HUDEye {
    static func density(_ across: Double, _ down: Double, _ time: Double, _ aspect: Double) -> Double {
        let px = across * aspect
        let width = min(aspect * 0.94, 1.75)
        let open = min(0.86, width * 0.6)
        let blinkPhase = time.truncatingRemainder(dividingBy: 7) / 7
        let blink = blinkPhase > 0.95 ? sin((blinkPhase - 0.95) / 0.05 * .pi) : 0
        let height = max(0.02, open * (1 - blink * 0.96))
        let ex = px / width
        let ey = down / height
        let reach = (ex * ex + ey * ey).squareRoot()
        let gradient = (ex * ex / (width * width) + ey * ey / (height * height)).squareRoot() / max(reach, 1e-6)
        let lid = (reach - 1) / max(gradient, 1e-6)
        let thick = down < 0 ? 0.075 : 0.05
        var level = abs(lid) < thick ? (down < 0 ? 1 : 0.75) : 0
        if abs(px) > width, abs(px) < width + 0.14, abs(down) < 0.035 {
            level = max(level, 0.6)
        }
        if down < 0, lid > thick, lid < thick + 0.14, height > open * 0.5 {
            let angle = atan2(-ey, ex)
            let tick = angle / .pi * 9
            if abs(tick - tick.rounded()) < 0.16, angle > 0.35, angle < .pi - 0.35 {
                level = max(level, 0.5)
            }
        }
        guard lid < -thick else { return level }
        return iris(px - width * 0.22 * sin(time * 0.28), down - open * 0.12 * sin(time * 0.19 + 1), time, open, down / height)
    }

    private static func iris(_ px: Double, _ py: Double, _ time: Double, _ open: Double, _ lidShare: Double) -> Double {
        let radius = (px * px + py * py).squareRoot()
        let iris = open * 0.72
        let pupil = iris * 0.36
        var level: Double
        if radius < pupil {
            level = 0
        } else if radius < pupil + 0.06 {
            level = 0.95
        } else if radius < iris - 0.05 {
            level = abs(sin(atan2(py, px) * 10 + time * 0.12)) < 0.32 ? 0.82 : 0.45
            if abs(radius - iris * 0.68) < 0.035 {
                level = 0.85
            }
        } else if radius < iris + 0.02 {
            level = 1
        } else {
            level = 0.07 + 0.12 * (1 - abs(lidShare))
        }
        if hypot(px + iris * 0.4, py + iris * 0.42) < iris * 0.16 {
            level = 1
        }
        return level
    }
}

/// Character art drawn as it is meant to be: Share Tech Mono with line height equal to the size, so the characters
/// stack into a picture, in `tone` with a soft phosphor bloom. Moving art redraws at 12 frames a second while the
/// panel shows and Reduce Motion is off; otherwise it holds its still frame. Arriving, it resolves top to bottom out
/// of ramp noise over 1.1 s.
struct HUDAsciiArt: View {
    let shape: HUDAscii.Shape
    let cols: Int
    let rows: Int
    /// Characters each way per footprint cell: the piece keeps its size with finer art.
    var detail = 2
    var grit = 0.35
    var seed = 1.0
    var tone = HUD.accent
    var label: String?
    /// The shell's hub: its links plug into the art.
    var hub = false
    /// Still art holds its first frame, as when nothing it stands for is happening.
    var animate = true
    @Environment(\.accessibilityReduceMotion) private var still
    @Environment(\.hudArrival) private var arrival

    var body: some View {
        let size = 12 / CGFloat(detail)
        let moving = animate && HUDPresence.shared.animating && !still
        let arriving = arrival.start != nil && HUDPresence.shared.animating
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !moving && !arriving)) { context in
            let time = moving ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) : 0
            let lines = HUDAscii.art(shape, cols: cols * detail, rows: rows * detail, seed: seed, grit: grit, time: time)
            let shown = arrival.elapsed(context.date).map {
                HUDMotion.resolve(lines, HUDMotion.progress($0, 0, 1.1), tick: Int($0 * 12), seed: seed)
            } ?? lines
            // Links plug into the whole drawing, not the part resolved so far.
            if hub {
                HUDAsciiText(lines: shown, cols: cols * detail, size: size, tone: tone, aspect: HUDAscii.artAspect)
                    .hudHub(art: lines)
            } else {
                HUDAsciiText(lines: shown, cols: cols * detail, size: size, tone: tone, aspect: HUDAscii.artAspect)
            }
        }
        .accessibilityElement()
        .accessibilityHidden(label == nil)
        .accessibilityLabel(label ?? "")
        .accessibilityAddTraits(.isImage)
    }
}

/// Lines of character art or banner, set on the design's grid of fixed cells (0.58 as wide as the line is tall), each
/// line scaled to fill its row exactly whatever the face's own metrics at this size.
struct HUDAsciiText: View {
    let lines: [String]
    let cols: Int
    let size: CGFloat
    var tone = HUD.accent
    /// Block characters (█▓▒░), which the design's fonts lack, are set in the system's monospaced face.
    var blocks = false
    /// A cell's width over its height: banners' by default, `HUDAscii.artAspect` for art.
    var aspect = HUDAscii.cellAspect
    @Environment(\.hudTheme) private var theme

    var body: some View {
        Canvas { context, canvas in
            let natural = context.resolve(styled(String(repeating: blocks ? "█" : "@", count: max(cols, 1))))
                .measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width
            if natural > 0 {
                context.scaleBy(x: canvas.width / natural, y: 1)
            }
            for (row, line) in lines.enumerated() where !line.isEmpty {
                context.draw(styled(line), at: CGPoint(x: 0, y: CGFloat(row) * size), anchor: .topLeading)
            }
        }
        .frame(width: CGFloat(cols) * size * (blocks ? 0.6 : aspect), height: CGFloat(lines.count) * size)
        .shadow(color: theme.color(tone.token).opacity(0.55), radius: 3)
        .accessibilityHidden(true)
    }

    private func styled(_ line: String) -> Text {
        let text = blocks ? Text(line).font(.system(size: size, design: .monospaced))
            : Text(line).font(.custom(HUDType.ascii.fontName, size: size)).tracking(size * 0.04)
        return text.foregroundStyle(theme.color(tone.token))
    }
}

/// Big titles drawn in characters, cut from the Xirod face: the letters are rasterised at `rows` cells tall and each
/// cell's ink is set through the density ramp, so any name reads as Xirod with a phosphor glow.
enum HUDBanner {
    /// `block` sets the ink in shaded blocks (█▓▒░) with a drop shadow, for the boot screen and splash.
    static func lines(_ text: String, rows: Int, tracking: Int = 2, block: Bool = false) -> [String] {
        _ = HUDFonts.registered
        guard let face = NSFont(name: HUDType.title.fontName, size: 100), face.capHeight > 0 else { return [] }
        let cellHeight: CGFloat = 8
        let cellWidth = cellHeight * HUDAscii.cellAspect
        let font = NSFont(name: HUDType.title.fontName, size: 100 * CGFloat(rows) * cellHeight / face.capHeight) ?? face
        var columns: [[Int]] = []
        for character in text.uppercased() {
            let glyph = NSAttributedString(string: String(character), attributes: [.font: font, .foregroundColor: NSColor.white])
            let cols = max(1, Int((glyph.size().width / cellWidth).rounded(.up)))
            columns += cells(glyph, cols: cols, rows: rows, cell: CGSize(width: cellWidth, height: cellHeight), descender: font.descender)
            columns += Array(repeating: Array(repeating: 0, count: rows), count: tracking)
        }
        if block {
            return blocks(columns, rows: rows)
        }
        return (0 ..< rows).map { row in
            String(columns.map { HUDAscii.ramp[$0[row]] }).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
    }

    private static func blocks(_ columns: [[Int]], rows: Int) -> [String] {
        (0 ... rows).map { row in
            let line = (0 ... columns.count).map { col -> Character in
                let ink = row < rows && col < columns.count ? columns[col][row] : 0
                if ink > 0 {
                    return ink >= 6 ? "█" : ink >= 4 ? "▓" : ink >= 2 ? "▒" : "░"
                }
                // The drop shadow: one cell down and right of solid ink.
                return row > 0 && col > 0 && col <= columns.count && columns[col - 1][row - 1] >= 5 ? "░" : " "
            }
            return String(line).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
    }

    /// One glyph's ink per cell, 0 to 9, column by column, the cap height filling the rows.
    private static func cells(_ glyph: NSAttributedString, cols: Int, rows: Int, cell: CGSize, descender: CGFloat) -> [[Int]] {
        let width = Int((CGFloat(cols) * cell.width).rounded(.up))
        let height = Int(CGFloat(rows) * cell.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // The baseline sits on the bottom edge, so the capitals fill the rows.
        glyph.draw(at: CGPoint(x: 0, y: descender))
        NSGraphicsContext.restoreGraphicsState()
        return (0 ..< cols).map { col in
            (0 ..< rows).map { row in
                var ink = 0
                var count = 0
                let left = Int(CGFloat(col) * cell.width)
                let right = min(width, Int(CGFloat(col + 1) * cell.width))
                // Bitmap rows run top-down, so the first text row is the top of the bitmap.
                for py in Int(CGFloat(row) * cell.height) ..< Int(CGFloat(row + 1) * cell.height) {
                    for px in left ..< max(left + 1, right) where px < width {
                        ink += Int(pixels[py * width + px])
                        count += 1
                    }
                }
                return count == 0 ? 0 : min(9, Int((Double(ink) / Double(count) / 255 * 9).rounded()))
            }
        }
    }
}

/// A rule made of characters with a centred label: `.:-=+*#%@ [ SESSION ] @%#*+=-:.`
struct HUDAsciiDivider: View {
    var label: String?
    var width = 64
    var tone = HUD.frame

    var body: some View {
        let title = label.map { "[ " + $0.uppercased() + " ]" } ?? ""
        let side = max(2, (width - title.count - (title.isEmpty ? 0 : 2)) / 2)
        let marks = Array(".:-=+*#%@")
        let left = String((0 ..< side).map { marks[min(marks.count - 1, $0 * marks.count / side)] })
        HStack(spacing: 0) {
            Text(left).font(.system(size: 11, design: .monospaced)).foregroundStyle(tone)
            if !title.isEmpty {
                Text(" " + title + " ").hudType(.data).tracking(0.88).foregroundStyle(HUD.inkMuted)
            }
            Text(String(left.reversed())).font(.system(size: 11, design: .monospaced)).foregroundStyle(tone)
        }
        .lineLimit(1)
        .accessibilityElement()
        .accessibilityLabel(label ?? "")
        .accessibilityAddTraits(.isHeader)
    }
}
