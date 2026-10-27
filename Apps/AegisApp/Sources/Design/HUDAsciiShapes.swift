import Foundation
import Synchronization

extension HUDAscii {
    static func orb(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let squared = across * across + down * down
        guard squared <= 1 else { return 0 }
        let depth = (1 - squared).squareRoot()
        let lightAcross = -0.5 * cos(time * 0.6) - 0.3 * sin(time * 0.6), lightDown = -0.6 + 0.15 * sin(time * 0.4)
        let lit = across * lightAcross + down * lightDown + depth * 0.62
        return min(max(0.15 + lit * 0.9, 0), 1)
    }

    static func reticle(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let radius = hypot(across, down), inner = 0.3 + 0.03 * sin(time * 2.4)
        var level = 0.0
        for (index, ring) in [0.95, 0.62, inner].enumerated() where abs(radius - ring) < (index == 1 ? 0.07 : 0.045) {
            level = max(level, index == 1 ? 0.9 : 0.6)
        }
        if abs(across) < 0.035 || abs(down) < 0.06, radius > 0.36, radius < 1.05 {
            level = max(level, 0.75)
        }
        if radius < 0.08 {
            level = 0.6 + 0.4 * abs(sin(time * 3))
        }
        let angle = atan2(down, across)
        if radius > 0.62, radius < 0.95, abs(sin(angle * 6 - time * 1.2)) < 0.12 {
            level = max(level, 0.45)
        }
        return level
    }

    static func heart(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let phase = time.truncatingRemainder(dividingBy: 1.2) / 1.2
        let beat = exp(-pow((phase - 0.08) / 0.05, 2)) + 0.6 * exp(-pow((phase - 0.28) / 0.05, 2))
        let scale = 1.25 / (1 + 0.08 * beat), px = across * scale, py = -down * scale + 0.25
        let squared = px * px + py * py - 1
        let field = squared * squared * squared - px * px * py * py * py
        return field <= 0 ? min(1, 0.55 + beat * 0.2 - field * 6) : 0
    }

    static func globe(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let squared = across * across + down * down
        guard squared <= 1 else { return 0 }
        let depth = (1 - squared).squareRoot(), latitude = asin(-down), longitude = atan2(across, depth) + 0.4 + time * 0.5
        let grid = abs(sin(latitude * 6)) < 0.16 || abs(sin(longitude * 6)) < 0.16
        return max(squared > 0.9 ? 0.85 : 0, grid ? 0.55 + depth * 0.4 : 0.08 + depth * 0.12)
    }

    static func tunnel(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let radius = hypot(across, down), angle = atan2(down, across)
        guard radius <= 1.04 else { return 0 }
        let depth = -log(max(radius, 0.02)), ring = wrap(depth * 2.6 - time * 1.5), near = min(1, radius * 1.4)
        var level = ring < 0.16 ? 0.35 + 0.6 * near : 0
        let rail = wrap(angle / (2 * .pi) * 12 + depth * 0.25 + time * 0.04)
        if abs(rail - 0.5) < 0.025 + 0.02 * near {
            level = max(level, 0.25 + 0.3 * near)
        }
        if radius < 0.14 {
            level = max(level, 1 - radius * 5)
        }
        return radius > 0.97 ? max(level, 0.7) : level
    }

    static func planet(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let tilt = -0.2, cosine = cos(tilt), sine = sin(tilt)
        let px = across * cosine - down * sine, py = across * sine + down * cosine
        let radius = 0.5, squared = across * across + down * down
        let ringDown = py / 0.24, ringRadius = hypot(px, ringDown)
        let inRing = ringRadius > 0.68 && ringRadius < 0.98 && !(ringRadius > 0.83 && ringRadius < 0.86)
        let ringLevel = inRing ? (ringRadius < 0.83 ? 0.5 : 0.32) : 0
        var level = ringLevel
        if squared < radius * radius {
            let depth = (radius * radius - squared).squareRoot() / radius
            let band = sin(py / radius * 7 + 0.3 * sin(px * 5 + time * 0.4))
            level = (0.3 + 0.7 * max(0, (-0.55 * across - 0.45 * down) / radius * 0.6 + depth * 0.6))
                * (band > 0.35 ? 1 : 0.7)
            if inRing, py > 0 {
                level = ringLevel
            } else if py > 0, ringRadius > 0.6, ringRadius <= 0.68 {
                level *= 0.35
            }
        }
        let angle = time * 0.5 + 2.2, moonAcross = cos(angle) * 0.92, moonDown = sin(angle) * 0.34
        let turnedAcross = moonAcross * cosine + moonDown * sine, turnedDown = -moonAcross * sine + moonDown * cosine
        let behind = sin(angle) < 0 && turnedAcross * turnedAcross + turnedDown * turnedDown < radius * radius
        if !behind, pow(across - turnedAcross, 2) + pow(down - turnedDown, 2) < 0.006 {
            level = 0.95
        }
        return min(1, level)
    }

    static func sun(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let radius = hypot(across, down), angle = atan2(down, across) - time * 0.18
        if radius < 0.36 {
            return 0.75 + 0.25 * (1 - radius / 0.36)
        }
        if radius < 0.42 {
            return 0.3
        }
        let sector = angle / (2 * .pi) * 16, fraction = wrap(sector)
        let ray = (sector.truncatingRemainder(dividingBy: 16) + 16).truncatingRemainder(dividingBy: 16).rounded(.down)
        let length = (ray.truncatingRemainder(dividingBy: 2) == 0 ? 0.95 : 0.72) + 0.05 * sin(time * 2 + ray)
        let width = 0.5 * (1 - (radius - 0.45) / (length - 0.45))
        return radius > 0.47 && radius < length && abs(fraction - 0.5) < width * 0.5
            ? 0.55 + 0.4 * (1 - (radius - 0.47) / (length - 0.47)) : 0
    }

    static func moon(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let radius = 0.62, squared = across * across + down * down
        if squared < radius * radius {
            let depth = (radius * radius - squared).squareRoot() / radius, phase = 2.1 + 0.06 * sin(time * 0.1)
            let lit = across / radius * cos(phase) * -1 + depth * sin(phase) * 0.2 - down / radius * 0.15
            var level = lit > 0.05 ? 0.55 + 0.4 * min(1, lit * 1.6) : 0.08 + 0.04 * depth
            for (centerAcross, centerDown, size) in [(-0.25, -0.2, 0.1), (-0.4, 0.18, 0.07), (-0.12, 0.32, 0.06), (-0.32, -0.42, 0.05)] {
                let distance = hypot(across - centerAcross, down - centerDown)
                if distance < size {
                    level *= lit > 0.05 ? 0.62 : 1
                } else if distance < size + 0.025, lit > 0.05 {
                    level = min(1, level + 0.12)
                }
            }
            return level
        }
        let cellAcross = (across * 9).rounded(.down), cellDown = (down * 9).rounded(.down)
        let starAcross = (cellAcross + 0.5) / 9, starDown = (cellDown + 0.5) / 9
        if hash(cellAcross, cellDown, 4) > 0.8, hypot(across - starAcross, down - starDown) < 0.03 {
            return 0.3 + 0.6 * abs(sin(time * (1 + hash(cellDown, cellAcross, 2) * 2) + cellAcross))
        }
        return 0
    }
}

extension HUDAscii {
    static func storm(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let flash = time.truncatingRemainder(dividingBy: 4.5) < 0.22 && time > 0
        let cloud = max(
            1 - hypot(across + 0.38, down + 0.3) / 0.32,
            1 - hypot(across - 0.02, down + 0.45) / 0.4,
            1 - hypot(across - 0.42, down + 0.26) / 0.3,
            across > -0.66 && across < 0.72 && down > -0.3 && down < -0.04 ? 0.4 : 0
        )
        if cloud > 0 {
            var level = 0.25 + 0.55 * min(1, cloud * 2.4) * (1 - (down + 0.85) * 0.45)
            if cloud < 0.12 {
                level = 0.85
            }
            return flash ? min(1, level + 0.3) : level
        }
        var level = 0.0
        if down > 0 {
            let column = ((across + down * 0.32) * 16).rounded(.down)
            let streak = wrap(down * 4.5 - time * 3.2 + hash(column, 1, 5) * 7)
            if hash(column, 2, 9) > 0.35, streak < 0.22 {
                level = 0.45
            }
        }
        if flash {
            let bolt = [(0.02, -0.05), (-0.1, 0.22), (0.06, 0.38), (-0.12, 0.66), (-0.02, 0.74), (-0.2, 0.98)]
            var distance = 9.0
            for index in 0 ..< bolt.count - 1 {
                let start = bolt[index], end = bolt[index + 1]
                let dx = end.0 - start.0, dy = end.1 - start.1
                let along = min(max(((across - start.0) * dx + (down - start.1) * dy) / (dx * dx + dy * dy), 0), 1)
                distance = min(distance, hypot(across - start.0 - along * dx, down - start.1 - along * dy))
            }
            if distance < 0.035 {
                level = 1
            } else if distance < 0.09 {
                level = max(level, 0.3)
            }
        }
        return level
    }

    static func chip(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let sideAcross = abs(across), sideDown = abs(down), outer = max(sideAcross, sideDown)
        if outer < 0.2 {
            let placeAcross = (across + 0.2) / 0.1, placeDown = (down + 0.2) / 0.1
            let coreAcross = placeAcross.rounded(.down), coreDown = placeDown.rounded(.down)
            let on = hash(coreAcross, coreDown, (time * 2.5).rounded(.down)) > 0.45
            let gap = placeAcross.truncatingRemainder(dividingBy: 1) < 0.15 || placeDown.truncatingRemainder(dividingBy: 1) < 0.15
            return gap ? 0.25 : on ? 0.9 : 0.4
        }
        if outer < 0.42 {
            return abs(outer - 0.4) < 0.025 || abs(outer - 0.22) < 0.02 ? 0.85 : 0.12
        }
        let side = sideAcross > sideDown ? (across > 0 ? 0.0 : 1.0) : (down > 0 ? 2.0 : 3.0)
        let along = sideAcross > sideDown ? down : across
        // JavaScript rounds negative halves toward positive infinity too.
        let pin = (along / 0.1 + 0.5).rounded(.down), offset = abs(along - pin * 0.1)
        let even = pin.truncatingRemainder(dividingBy: 2) == 0
        if abs(pin) <= 3, offset < 0.022 {
            if outer < 0.52 {
                return 0.75
            }
            if even, outer < 0.98 {
                let pulse = wrap(outer * 3 - time * 1.4 + hash(pin, side, 6) * 3)
                return pulse < 0.12 ? 1 : 0.3
            }
        }
        return outer > 0.92 && outer < 0.98 && abs(along) < 0.33 && offset < 0.04 && abs(pin) <= 3 && even ? 0.7 : 0
    }

    static func rain(column: Int?, row: Int, rows: Int, time: Double) -> Double {
        guard let column else { return 0 }
        let cellAcross = Double(column), cellDown = Double(row)
        let speed = 6 + hash(cellAcross, 1, 3) * 14, length = 5 + hash(cellAcross, 2, 3) * 14
        let span = Double(rows) + length + 6
        let head = ((time + 3) * speed + hash(cellAcross, 3, 3) * span).truncatingRemainder(dividingBy: span)
        let behind = head - cellDown
        if behind < 0 || behind > length {
            return hash(cellAcross, cellDown, 9) > 0.985 ? 0.15 : 0
        }
        return behind < 1 ? 1 : 0.85 * (1 - behind / length) + 0.08
    }

    static func city(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let px = (across + 1) / 2, py = (down + 1) / 2
        let tower = (px * 13).rounded(.down), along = px * 13 - tower
        let height = tower == 5 ? 0.94 : 0.25 + 0.65 * pow(hash(tower, 1, 11), 1.4), top = 1 - height
        if py < top {
            if tower == 5, abs(along - 0.5) < 0.06, py > top - 0.12 {
                return py < top - 0.1 ? (time.truncatingRemainder(dividingBy: 1.4) < 0.7 ? 1 : 0.2) : 0.6
            }
            return hash((px * 120).rounded(.down), (py * 40).rounded(.down), 2) > 0.992 ? 0.35 : 0
        }
        if along < 0.07 || along > 0.93 || py - top < 0.015 {
            return 0.7
        }
        let windowAcross = (along * 5).truncatingRemainder(dividingBy: 1)
        let windowDown = ((py - top) * 26).truncatingRemainder(dividingBy: 1)
        if windowAcross > 0.3, windowAcross < 0.75, windowDown > 0.3, windowDown < 0.8 {
            let seed = (time / 2.5 + hash(tower, 3, 1) * 4).rounded(.down)
            return hash(tower * 7 + (along * 5).rounded(.down), ((py - top) * 26).rounded(.down), seed) > 0.55 ? 0.85 : 0.12
        }
        return 0.18
    }

    static func blackhole(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let radius = hypot(across, down), angle = atan2(down, across), discDown = down / 0.24
        let discRadius = hypot(across, discDown)
        let disc = discRadius > 0.3 && discRadius < 1
            ? (0.5 + 0.5 * cos(atan2(discDown, across) * 3 - log(discRadius) * 9 + time * 2.2)) * (1 - discRadius) * 1.2
            + 0.25 * (across < 0 ? 1 : 0.4) : 0
        var level = 0.0
        if down < 0, radius > 0.27, radius < 0.46, abs(across) < 0.6 {
            level = max(level, 0.5 * (1 - (radius - 0.27) / 0.19) + 0.15 * (0.5 + 0.5 * sin(angle * 6 + time)))
        }
        if radius < 0.25 {
            level = 0
        }
        if abs(radius - 0.265) < 0.022 {
            level = 1
        }
        if disc > 0, down > 0 || radius > 0.25 {
            level = max(level, min(1, disc))
        }
        return level
    }
}

extension HUDAscii {
    static func floorplan(_ across: Double, _ down: Double, _ time: Double, _ aspect: Double) -> Double {
        let scale = min(aspect * 2 / 32, 2.0 / 18), px = across * aspect / scale + 16, py = down / scale + 9
        let width = 0.32
        guard px >= -0.6, px <= 32.6, py >= -0.6, py <= 18.6 else { return 0 }
        func inside(_ left: Double, _ top: Double, _ right: Double, _ bottom: Double) -> Bool {
            px > left && px < right && py > top && py < bottom
        }
        if floorplanWall(px, py, width) {
            return 0.95
        }
        let pulse = 0.5 + 0.5 * sin(time * 3.2)
        if px < 0.4, py > 2, py < 8 {
            return time != 0 ? (wrap(py * 1.5 - time * 4) < 0.5 ? 0.85 : 0.2) : 0.6
        }
        if px < -0.2 {
            return 0
        }
        if abs(py - 18) < width + 0.05, px > 20, px < 22.4 {
            return 0.55
        }
        if inside(2.6, 3, 7.6, 7.2) {
            let carAcross = abs(px - 5.1), carDown = abs(py - 5.1)
            if carAcross > 2.3 || carDown > 1.9 {
                return 0.75
            }
            return carAcross < 1.4 && carDown < 1.1 ? 0.35 : 0.12
        }
        if inside(0, 0, 10, 10) {
            return 0.08 + 0.2 * pulse * (time != 0 ? 1 : 0.5)
        }
        let lit = [(10.0, 0.0, 22.0, 10.0, 16.0, 4.5), (22, 0, 32, 10, 27, 5)]
        for (index, room) in lit.enumerated() where inside(room.0, room.1, room.2, room.3) {
            let radius = hypot(px - room.4, py - room.5)
            return max(0.06, 0.42 - radius * 0.06) + (time != 0 ? 0.02 * sin(time * 5 + Double(index)) : 0)
        }
        if inside(0, 10, 32, 18) {
            return hash((px * 2).rounded(.down), (py * 2).rounded(.down), 5) > 0.93 ? 0.05 : 0
        }
        return 0
    }

    private static func floorplanWall(_ px: Double, _ py: Double, _ width: Double) -> Bool {
        let walls = [
            (0.0, 0.0, 32.0, 0.0),
            (0, 18, 32, 18),
            (0, 0, 0, 18),
            (32, 0, 32, 18),
            (10, 0, 10, 10),
            (22, 0, 22, 10),
            (0, 10, 32, 10),
            (12, 10, 12, 18),
            (18, 10, 18, 18),
        ]
        let gaps = [
            (10.0, 6.0, 10.0, 8.0),
            (22, 3, 22, 5),
            (4, 10, 6, 10),
            (14, 10, 16, 10),
            (24, 10, 26, 10),
            (0, 2, 0, 8),
            (20, 18, 22.4, 18),
        ]
        let onWall = walls.contains { wall in
            wall.0 == wall.2
                ? abs(px - wall.0) < width && py >= wall.1 - width && py <= wall.3 + width
                : abs(py - wall.1) < width && px >= wall.0 - width && px <= wall.2 + width
        }
        let inGap = gaps.contains { gap in
            gap.0 == gap.2
                ? abs(px - gap.0) < width + 0.01 && py > gap.1 && py < gap.3
                : abs(py - gap.1) < width + 0.01 && px > gap.0 && px < gap.2
        }
        return onWall && !inGap
    }

    static func torus(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let tilt = 1.05 + 0.32 * sin(time * 0.45), turn = 0.35 * sin(time * 0.3)
        let tiltCos = cos(tilt), tiltSin = sin(tilt), turnCos = cos(turn), turnSin = sin(turn)
        func rotate(_ px: Double, _ py: Double, _ pz: Double) -> Point3D {
            let tiltedDown = py * tiltCos - pz * tiltSin, tiltedDepth = py * tiltSin + pz * tiltCos
            return Point3D(across: px * turnCos - tiltedDown * turnSin, down: px * turnSin + tiltedDown * turnCos, depth: tiltedDepth)
        }
        func field(_ px: Double, _ py: Double, _ pz: Double) -> Double {
            let point = rotate(px, py, pz), ring = hypot(point.across, point.depth) - 0.6
            return hypot(ring, point.down) - 0.28
        }
        var depth = -1.4, distance = 0.0
        for _ in 0 ..< 30 {
            distance = field(across, down, depth)
            if distance < 0.004 {
                break
            }
            depth += distance
            if depth > 1.4 {
                return 0
            }
        }
        guard distance <= 0.01 else { return 0 }
        let epsilon = 0.01
        let normalAcross = field(across + epsilon, down, depth) - field(across - epsilon, down, depth)
        let normalDown = field(across, down + epsilon, depth) - field(across, down - epsilon, depth)
        let normalDepth = field(across, down, depth + epsilon) - field(across, down, depth - epsilon)
        let length = (normalAcross * normalAcross + normalDown * normalDown + normalDepth * normalDepth).squareRoot()
        let lit = max(0, (-0.45 * normalAcross - 0.62 * normalDown - 0.64 * normalDepth) / (length == 0 ? 1 : length))
        let point = rotate(across, down, depth), band = wrap(atan2(point.depth, point.across) / (2 * .pi) * 18 + time * 0.9)
        return max(0.1, min(1, (0.14 + 0.86 * lit) * (band < 0.22 ? 0.55 : 1)))
    }
}

extension HUDAscii {
    private struct Point3D: Sendable {
        let across: Double, down: Double, depth: Double
    }

    private struct HyperFrame: Sendable {
        let time: Double
        let vertices: [Point3D]
        let edges: [(Point3D, Point3D)]
    }

    private static let hyperFrame = Mutex<HyperFrame?>(nil)

    static func tesseract(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let frame = tesseractFrame(time)
        var level = 0.0
        for (start, end) in frame.edges {
            guard across >= min(start.across, end.across) - 0.07, across <= max(start.across, end.across) + 0.07,
                  down >= min(start.down, end.down) - 0.07, down <= max(start.down, end.down) + 0.07 else { continue }
            let dx = end.across - start.across, dy = end.down - start.down, squared = dx * dx + dy * dy
            let along = min(max(((across - start.across) * dx + (down - start.down) * dy) / (squared == 0 ? 1e-6 : squared), 0), 1)
            let ex = start.across + dx * along - across, ey = start.down + dy * along - down
            let distanceSquared = ex * ex + ey * ey, depth = start.depth + (end.depth - start.depth) * along
            let width = 0.035 + 0.03 * depth
            if distanceSquared < width * width {
                level = max(level, (1 - distanceSquared.squareRoot() / width) * (0.35 + 0.65 * depth) + 0.12)
            }
        }
        for point in frame.vertices where abs(across - point.across) < 0.05 && abs(down - point.down) < 0.05 {
            level = max(level, 0.95)
        }
        return min(1, level)
    }

    private static func tesseractFrame(_ time: Double) -> HyperFrame {
        hyperFrame.withLock { cached in
            if let cached, cached.time == time {
                return cached
            }
            let angle = time * 0.5, tilt = time * 0.33 + 0.6, turn = 0.5 + time * 0.2
            let vertices = (0 ..< 16).map { corner -> Point3D in
                let px = corner & 1 == 0 ? -1.0 : 1, py = corner & 2 == 0 ? -1.0 : 1
                let pz = corner & 4 == 0 ? -1.0 : 1, pw = corner & 8 == 0 ? -1.0 : 1
                let turnedAcross = px * cos(angle) - pw * sin(angle), turnedFourth = px * sin(angle) + pw * cos(angle)
                let turnedDepth = pz * cos(tilt) - turnedFourth * sin(tilt), fourth = pz * sin(tilt) + turnedFourth * cos(tilt)
                let scale4 = 1 / (2.6 - fourth), xx = turnedAcross * scale4, yy = py * scale4, zz = turnedDepth * scale4
                let across3 = xx * cos(turn) + zz * sin(turn), depth3 = -xx * sin(turn) + zz * cos(turn)
                let down3 = yy * cos(0.45) - depth3 * sin(0.45), depth = yy * sin(0.45) + depth3 * cos(0.45)
                let scale3 = 1.55 / (2.2 - depth)
                return Point3D(across: across3 * scale3, down: down3 * scale3, depth: (fourth + 1) / 2)
            }
            var edges: [(Point3D, Point3D)] = []
            for first in 0 ..< 16 {
                for second in first + 1 ..< 16 where [1, 2, 4, 8].contains(first ^ second) {
                    edges.append((vertices[first], vertices[second]))
                }
            }
            let frame = HyperFrame(time: time, vertices: vertices, edges: edges)
            cached = frame
            return frame
        }
    }

    private struct Electron: Sendable {
        let across: Double, down: Double, radius: Double, level: Double
    }

    private struct Orbit: Sendable {
        let cosine: Double, sine: Double
        let electrons: [Electron]
    }

    private struct AtomFrame: Sendable {
        let time: Double
        let orbits: [Orbit]
    }

    private static let atomFrame = Mutex<AtomFrame?>(nil)

    static func atom(_ across: Double, _ down: Double, _ time: Double) -> Double {
        let radius = hypot(across, down), major = 0.92, minor = 0.3
        var level = radius < 0.14 ? 0.6 + 0.35 * abs(sin(across * 30 + time * 2) * cos(down * 30 - time * 1.6)) : 0
        for orbit in atomOrbits(time) {
            let px = across * orbit.cosine + down * orbit.sine, py = -across * orbit.sine + down * orbit.cosine
            let ellipse = (px * px / (major * major) + py * py / (minor * minor)).squareRoot()
            let gradient = (px * px / pow(major, 4) + py * py / pow(minor, 4)).squareRoot() / max(ellipse, 1e-6)
            if abs(ellipse - 1) / max(gradient, 1e-6) < 0.03 {
                level = max(level, 0.4)
            }
            for electron in orbit.electrons {
                let dx = across - electron.across, dy = down - electron.down
                if dx * dx + dy * dy < electron.radius * electron.radius {
                    level = max(level, electron.level)
                }
            }
        }
        return level
    }

    private static func atomOrbits(_ time: Double) -> [Orbit] {
        atomFrame.withLock { cached in
            if let cached, cached.time == time {
                return cached.orbits
            }
            let orbits = (0 ..< 3).map { index -> Orbit in
                let orbit = Double(index), angle = orbit * .pi / 3 + 0.3, cosine = cos(angle), sine = sin(angle)
                let electrons = (0 ..< 6).map { trail -> Electron in
                    let phase = time * (1.3 + orbit * 0.4) + orbit * 2.1 - Double(trail) * 0.11
                    let px = 0.92 * cos(phase), py = 0.3 * sin(phase)
                    return Electron(
                        across: px * cosine - py * sine,
                        down: px * sine + py * cosine,
                        radius: trail == 0 ? 0.07 : 0.045,
                        level: trail == 0 ? 1 : 0.85 - Double(trail) * 0.12
                    )
                }
                return Orbit(cosine: cosine, sine: sine, electrons: electrons)
            }
            cached = AtomFrame(time: time, orbits: orbits)
            return orbits
        }
    }
}
