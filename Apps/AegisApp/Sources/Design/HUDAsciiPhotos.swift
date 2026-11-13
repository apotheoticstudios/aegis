import Foundation
import Synchronization

/// The design system's photo shapes (#186): reference photographs converted to density maps (background removed,
/// tones equalised, edges sharpened, 150 cells on the long side), each moving through its own parts and then run
/// through the grit: grain, speckle and dropouts, a misregistered ghost beside it like a bad photocopy, and the odd
/// horizontal tear. Ported from the design's generators; `reform` is drawn rather than photographed.
enum HUDPhoto {
    /// One photograph as the design stores it in `Resources/Brand/ascii-photos.json`: each cell's low 4 bits are its
    /// level and bit 4 marks the part that moves on its own; runs of empty cells are packed as "!" and a count.
    struct Map: Sendable {
        let width: Int
        let height: Int
        let cells: [UInt8]
        /// The subject's box in the original photograph (x, y, width, height as fractions), for points given there.
        var crop = [0.0, 0, 1, 1]
        /// The original photograph's long side over the stored one's, for lengths given there.
        var scale = 1.0

        var side: Int {
            max(width, height)
        }
    }

    static let maps: [String: Map] = load(Bundle.main.url(forResource: "ascii-photos", withExtension: "json", subdirectory: "Brand"))

    /// The maps by name; empty when the file is missing or damaged, so the art draws nothing rather than failing.
    static func load(_ url: URL?) -> [String: Map] {
        struct Stored: Decodable {
            let w: Int, h: Int, d: String
            let c: [Double]?
            let k: Double?
        }
        guard let url, let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: data)
        else { return [:] }
        return stored.compactMapValues { photo in
            let cells = unpack(photo.d, count: photo.w * photo.h)
            guard cells.count == photo.w * photo.h else { return nil }
            return Map(width: photo.w, height: photo.h, cells: cells, crop: photo.c ?? [0, 0, 1, 1], scale: photo.k ?? 1)
        }
    }

    /// The design's packing: base-64 digits, with "!" and a digit for that many plus one empty cells.
    static func unpack(_ packed: String, count: Int) -> [UInt8] {
        var digit = [UInt8](repeating: 255, count: 128)
        for (value, character) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
            digit[Int(character)] = UInt8(value)
        }
        var cells = [UInt8](repeating: 0, count: count)
        var index = 0
        var run = false
        for character in packed.utf8 where Int(character) < 128 {
            if character == UInt8(ascii: "!") {
                run = true
                continue
            }
            let value = digit[Int(character)]
            guard value != 255 else { return [] }
            if run {
                index += Int(value) + 1
                run = false
            } else {
                guard index < count else { return [] }
                cells[index] = value
                index += 1
            }
        }
        return index == count ? cells : []
    }

    /// The shape's density at (across, down), already fitted to the shorter side, in a box `aspect` wide per tall.
    static func density(_ shape: HUDAscii.Shape, _ across: Double, _ down: Double, _ time: Double, _ aspect: Double) -> Double {
        let photo = Photo(shape.photoName, aspect: aspect)
        return grit(across, down, time) { u, v in
            raw(shape, u, v, time, photo)
        }
    }

    /// A photograph framed in the box: a wide one fills a wide box, a tall one a tall box.
    struct Photo {
        let map: Map?
        let zoom: Double

        init(_ name: String?, aspect: Double) {
            map = name.flatMap { HUDPhoto.maps[$0] }
            guard let map else {
                zoom = 1
                return
            }
            let side = Double(map.side)
            let width = 0.96 * Double(map.width) / side, height = 0.96 * Double(map.height) / side
            zoom = max(1, min(max(aspect, 1) / width, max(1 / aspect, 1) / height))
        }

        /// The cell at (u, v), or 0 outside the photograph.
        func at(_ u: Double, _ v: Double) -> UInt8 {
            guard let map else { return 0 }
            let side = Double(map.side)
            let x = Int((((u / zoom) / 0.96 + 1) / 2 * side - (side - Double(map.width)) / 2).rounded(.down))
            let y = Int((((v / zoom) / 0.96 + 1) / 2 * side - (side - Double(map.height)) / 2).rounded(.down))
            return x < 0 || y < 0 || x >= map.width || y >= map.height ? 0 : map.cells[y * map.width + x]
        }

        func level(_ u: Double, _ v: Double) -> Double {
            HUDPhoto.level(at(u, v))
        }

        /// A point given as a fraction across and down the original photograph.
        func point(_ x: Double, _ y: Double) -> (Double, Double) {
            guard let map else { return (0, 0) }
            let side = Double(map.side)
            let x = (x - map.crop[0]) / map.crop[2], y = (y - map.crop[1]) / map.crop[3]
            return (
                ((x * Double(map.width) + (side - Double(map.width)) / 2) / side * 2 - 1) * 0.96 * zoom,
                ((y * Double(map.height) + (side - Double(map.height)) / 2) / side * 2 - 1) * 0.96 * zoom
            )
        }

        /// A length given as a fraction of the original photograph's long side.
        func length(_ fraction: Double) -> Double {
            fraction * (map?.scale ?? 1) * 2 * 0.96 * zoom
        }
    }

    static func level(_ cell: UInt8) -> Double {
        Double(cell & 15) / 15
    }

    static func moves(_ cell: UInt8) -> Bool {
        cell & 16 != 0
    }

    private static func hash(_ x: Double, _ y: Double, _ seed: Double) -> Double {
        HUDAscii.hash(x, y, seed)
    }

    private static func rotate(_ u: Double, _ v: Double, _ centre: (Double, Double), _ angle: Double) -> (Double, Double) {
        let x = u - centre.0, y = v - centre.1
        return (centre.0 + x * cos(angle) - y * sin(angle), centre.1 + x * sin(angle) + y * cos(angle))
    }

    /// The grit: film grain, speckle and dropouts over the photograph's own tones, a misregistered ghost beside it,
    /// and the odd horizontal tear. Detail is kept; nothing is smoothed.
    private static func grit(_ u: Double, _ v: Double, _ time: Double, _ shape: (Double, Double) -> Double) -> Double {
        var torn = u
        if time > 0 {
            let tear = hash(((v + 1) * 16).rounded(.down), (time * 2.5).rounded(.down), 11)
            if tear > 0.955 {
                torn = u + (tear - 0.9775) * 2.2
            }
        }
        var level = shape(torn, v)
        let cellX = ((u + 2) * 44).rounded(.down), cellY = ((v + 2) * 44).rounded(.down), noise = hash(cellX, cellY, 17)
        if level <= 0.02 {
            let ghost = shape(torn - 0.04, v - 0.026)
            return ghost > 0.55 && hash(cellX, cellY, 5) > 0.45 ? 0.2 : noise > 0.994 ? 0.3 : 0
        }
        level += (noise - 0.5) * 0.12
        if noise > 0.985 {
            level = min(1, level + 0.45)
        } else if noise < 0.02 {
            level *= 0.2
        }
        if time > 0, hash(cellX, cellY, 31 + (time * 6).rounded(.down)) > 0.986 {
            level = level > 0.6 ? 0.22 : 0.95
        }
        return max(0.03, min(1, level))
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func raw(_ shape: HUDAscii.Shape, _ u: Double, _ v: Double, _ time: Double, _ photo: Photo) -> Double {
        switch shape {
        case .satellite: satellite(u, v, time, photo)
        case .laptop: laptop(u, v, time, photo)
        case .house: house(u, v, time, photo)
        case .vault: vault(u, v, time, photo)
        case .lighthouse: lighthouse(u, v, time, photo)
        case .lock: lock(u, v, time, photo)
        case .shutter: shutter(u, v, time, photo)
        case .bulb: bulb(u, v, time, photo)
        case .gears: gears(u, v, time, photo)
        case .reform: reform(u, v, time)
        default: 0
        }
    }

    /// A radio dish: signal pulses out from the feed.
    private static func satellite(_ u: Double, _ v: Double, _ t: Double, _ photo: Photo) -> Double {
        var level = photo.level(u, v)
        let feed = photo.point(0.66, 0.06)
        let distance = hypot(u - feed.0, v - feed.1), angle = atan2(v - feed.1, u - feed.0)
        if angle > -2.6, angle < -0.2, distance > 0.08 {
            for ring in 0 ..< 3 {
                let radius = (t * 0.3 + Double(ring) / 3).truncatingRemainder(dividingBy: 1) * 0.6 + 0.08
                if abs(distance - radius) < 0.022 {
                    level = max(level, 0.95 - (radius - 0.08))
                }
            }
        }
        return level
    }

    /// A laptop: code scrolls on its screen and a scan line reads it.
    private static func laptop(_ u: Double, _ v: Double, _ t: Double, _ photo: Photo) -> Double {
        let cell = photo.at(u, v)
        guard moves(cell) else { return level(cell) }
        let y = (v + 1) * 20 + t * 1.6, line = y.rounded(.down), within = y - line
        let indent = (hash(line, 1, 5) * 4).rounded(.down) * 0.06, length = 0.15 + hash(line, 2, 5) * 0.5, left = -0.2
        let code = within > 0.25 && within < 0.75 && u > left + indent && u < left + indent + length
            && hash((u * 24).rounded(.down), line, 6) > 0.2
        var level = code ? (hash(line, 3, 5) > 0.7 ? 0.95 : 0.6) : 0.06
        let scan = t > 0 ? (t * 0.35).truncatingRemainder(dividingBy: 1.4) * 1.2 - 0.85 : -2
        if abs(v - scan) < 0.022 {
            level = 0.9
        }
        return level
    }

    /// A house: its windows light up and go dark, one by one.
    private static func house(_ u: Double, _ v: Double, _ t: Double, _ photo: Photo) -> Double {
        let cell = photo.at(u, v)
        guard moves(cell) else { return level(cell) }
        let window = ((u + 1) * 7).rounded(.down) * 5 + ((v + 1) * 3).rounded(.down)
        let lit = hash(window, 2, (t / 2.4 + hash(window, 5, 1) * 3).rounded(.down)) > 0.45
        return lit ? 0.75 + (t > 0 ? 0.08 * sin(t * 5 + window) : 0) : level(cell) * 0.6
    }

    /// A vault door: the wheel spins one way, pauses, and spins back.
    private static func vault(_ u: Double, _ v: Double, _ t: Double, _ photo: Photo) -> Double {
        let cell = photo.at(u, v)
        guard moves(cell) else { return level(cell) }
        let turned = rotate(u, v, photo.point(0.5, 0.497), -(t > 0 ? sin(t * 0.5) * 3.6 : 0))
        let wheel = photo.at(turned.0, turned.1)
        return moves(wheel) ? level(wheel) : level(cell)
    }

    /// A lighthouse: the lamp swings its beam out over the dark and flares as it faces you.
    private static func lighthouse(_ u: Double, _ v: Double, _ t: Double, _ photo: Photo) -> Double {
        let cell = photo.at(u, v)
        let phase = t > 0 ? t * 0.85 : 0.5, swing = cos(phase), face = sin(phase)
        if moves(cell) {
            return 0.55 + 0.45 * max(0, face)
        }
        var level = level(cell)
        guard level <= 0 else { return level }
        let lamp = photo.point(0.5, 0.115)
        let dx = u - lamp.0, dy = v - lamp.1, side: Double = swing >= 0 ? 1 : -1, reach = 1.6 * (0.3 + 0.7 * abs(swing))
        if dx * side > 0.06, abs(dy) < 0.02 + abs(dx) * 0.13, abs(dx) < reach {
            level = (abs(dy) < 0.01 + abs(dx) * 0.05 ? 0.8 : 0.45) * (1 - abs(dx) / reach * 0.6)
        }
        let distance = hypot(dx, dy)
        if face > 0.5, distance < 0.05 + face * 0.12 {
            level = max(level, 0.5 + 0.5 * face * (1 - distance / 0.17))
        }
        return level
    }

    /// A padlock: the shackle lifts open, hangs, then snaps shut with a flash.
    private static func lock(_ u: Double, _ v: Double, _ t: Double, _ photo: Photo) -> Double {
        let cycle = t > 0 ? t.truncatingRemainder(dividingBy: 6.5) / 6.5 : 0.2
        let lift = cycle < 0.45 ? 0 : cycle < 0.55 ? (cycle - 0.45) / 0.1 * 0.2 : cycle < 0.86 ? 0.2
            : cycle < 0.88 ? 0.2 * (1 - (cycle - 0.86) / 0.02) : 0
        let body = photo.at(u, v), shackle = photo.at(u, v + lift)
        var level = moves(body) ? 0 : level(body)
        if moves(shackle) {
            level = max(level, HUDPhoto.level(shackle))
        }
        if cycle >= 0.88, cycle < 0.95, abs(hypot(u, v) - (cycle - 0.88) / 0.07 * 1.2) < 0.035 {
            level = max(level, 0.9)
        }
        return level
    }

    /// A lens: the iris turns and opens wide, then closes down again.
    private static func shutter(_ u: Double, _ v: Double, _ t: Double, _ photo: Photo) -> Double {
        let cell = photo.at(u, v)
        guard moves(cell) else { return level(cell) }
        let centre = photo.point(0.5, 0.5), iris = photo.length(0.335)
        let opening = t > 0 ? 0.95 + 0.3 * sin(t * 0.6) : 1, turn = t > 0 ? sin(t * 0.6) * 0.5 : 0
        let x = u - centre.0, y = v - centre.1, radius = hypot(x, y) * opening, angle = atan2(y, x) - turn
        guard radius <= iris * 0.99 else { return 0.18 }
        return photo.level(centre.0 + cos(angle) * radius, centre.1 + sin(angle) * radius)
    }

    /// A filament bulb: the glass glows and flickers; now and then it clicks off.
    private static func bulb(_ u: Double, _ v: Double, _ t: Double, _ photo: Photo) -> Double {
        let cycle = t > 0 ? t.truncatingRemainder(dividingBy: 8) / 8 : 0.3, on = !(cycle > 0.82 && cycle < 0.9)
        let flicker = t > 0 && on && hash((t * 9).rounded(.down), 1, 7) > 0.9 ? 0.55 : 1
        let cell = photo.at(u, v)
        var level = level(cell)
        if moves(cell) {
            return on ? min(1, level * (0.85 + 0.3 * flicker)) : level * 0.4
        }
        guard level <= 0, on else { return level }
        let centre = photo.point(0.5, 0.33), glass = photo.length(0.3)
        let x = u - centre.0, y = v - centre.1, radius = hypot(x, y), turns = atan2(y, x) / (.pi * 2) * 16
        let ray = abs((turns.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) - 0.5)
        if radius > glass * 1.12, radius < glass * 1.4, y < glass * 0.4, ray < 0.08 {
            level = flicker > 0.6 ? 0.85 : 0.45
        }
        return level
    }

    /// Five chrome gears, each turning on its own axle against its neighbours, smaller ones faster.
    private static func gears(_ u: Double, _ v: Double, _ t: Double, _ photo: Photo) -> Double {
        // [x, y, radius] in the original 736 × 1057 photograph, and the way each turns (1 or -1).
        let axles: [[Double]] = [[424, 240, 220, 1], [258, 413, 110, -1], [432, 532, 152, -1], [152, 685, 137, 1], [443, 852, 212, 1]]
        var nearest: [Double]?
        var centre = (0.0, 0.0)
        var closest = 1.05
        for axle in axles {
            let middle = photo.point(axle[0] / 736, axle[1] / 1057),
                reach = hypot(u - middle.0, v - middle.1) / photo.length(axle[2] / 1057)
            if reach < closest {
                closest = reach
                nearest = axle
                centre = middle
            }
        }
        guard let gear = nearest, t > 0 else { return photo.level(u, v) }
        let turned = rotate(u, v, centre, -(t * 0.32 * gear[3] * min(2.2, 60 / gear[2])))
        return photo.level(turned.0, turned.1)
    }

    // MARK: - Reform

    /// Starting again: a sphere of particles bursts apart, drifts, and gathers back into shape.
    private static func reform(_ u: Double, _ v: Double, _ t: Double) -> Double {
        let frame = Reform.frame(t)
        var level = 0.0
        for particle in frame.particles {
            let dx = u - particle.0, dy = v - particle.1
            guard dx > -0.05, dx < 0.05, dy > -0.06, dy < 0.06 else { continue }
            let size = 0.028 + 0.02 * particle.2
            if dx * dx + dy * dy < size * size {
                level = max(level, 0.35 + 0.65 * particle.2)
            }
        }
        let distance = hypot(u, v)
        if frame.spread < 0.05, distance < 0.62 {
            level = max(level, 0.06 + 0.12 * (1 - distance / 0.62))
        }
        if frame.cycle > 0.4, frame.cycle < 0.5, abs(distance - (frame.cycle - 0.4) / 0.1 * 1.1) < 0.035 {
            level = max(level, 0.9 * (1 - (frame.cycle - 0.4) / 0.1))
        }
        return level
    }

    /// The particles for one moment, worked out once per frame rather than for every cell.
    private enum Reform {
        struct Frame: Sendable {
            let time: Double
            let particles: [(Double, Double, Double)]
            let spread: Double
            let cycle: Double
        }

        /// 150 points spread evenly over a sphere, each with the direction it bursts in.
        static let points: [[Double]] = (0 ..< 150).map { index in
            let n = Double(index), y = 1 - (n + 0.5) / 150 * 2, ring = (1 - y * y).squareRoot(), angle = n * 2.39996
            return [
                cos(angle) * ring,
                y,
                sin(angle) * ring,
                HUDAscii.hash(n, 1, 3) * 2 - 1,
                HUDAscii.hash(n, 2, 3) * 2 - 1,
                HUDAscii.hash(n, 3, 3) * 2 - 1,
            ]
        }

        private static let last = Mutex<Frame?>(nil)

        static func frame(_ t: Double) -> Frame {
            if let frame = last.withLock({ $0 }), frame.time == t {
                return frame
            }
            let cycle = t > 0 ? t.truncatingRemainder(dividingBy: 9) / 9 : 0
            let eased = cycle < 0.4 ? 0 : cycle < 0.55 ? ((cycle - 0.4) / 0.15).squareRoot() : cycle < 0.72 ? 1
                : cycle < 0.95 ? 1 - pow((cycle - 0.72) / 0.23, 2) * (3 - 2 * (cycle - 0.72) / 0.23) : 0
            let spread = max(0, min(1, eased)), spin = t * 0.5, ca = cos(spin), sa = sin(spin)
            let particles = points.map { point in
                let x = point[0] * 0.62 + point[3] * spread * 0.7
                let y = point[1] * 0.62 + point[4] * spread * 0.6 - spread * spread * 0.1
                let z = point[2] * 0.62 + point[5] * spread * 0.7
                return (x * ca + z * sa, y, (-x * sa + z * ca + 1.4) / 2.8)
            }
            let frame = Frame(time: t, particles: particles, spread: spread, cycle: cycle)
            last.withLock { $0 = frame }
            return frame
        }
    }
}

extension HUDAscii.Shape {
    /// The photograph a photo shape draws from; nil for drawn shapes.
    var photoName: String? {
        switch self {
        case .satellite: "satellite"
        case .laptop: "laptop"
        case .house: "house"
        case .vault: "vault"
        case .lighthouse: "lighthouse"
        case .lock: "lock"
        case .shutter: "shutter"
        case .bulb: "bulb"
        case .gears: "gears"
        default: nil
        }
    }
}
