import Foundation

/// An anatomical heart: ventricles, atria, the aorta and its branches, the pulmonary trunk, the venae cavae and
/// coronary vessels that flush with each beat. It beats lub-dub at about 67 a minute.
enum HUDAnatomy {
    private struct Point {
        let across: Double
        let down: Double
    }

    private struct Segment {
        let distance: Double
        let along: Double
        let dx: Double
        let dy: Double
    }

    static func density(_ across0: Double, _ down0: Double, _ time: Double) -> Double {
        let at = Point(across: across0 * 1.04 + 0.05, down: down0 * 1.06 - 0.06)
        let phase = time.truncatingRemainder(dividingBy: 0.9) / 0.9
        let beat = exp(-pow((phase - 0.08) / 0.06, 2)) + 0.55 * exp(-pow((phase - 0.3) / 0.06, 2))
        let squeeze = 1 - 0.07 * beat
        let swell = 1 + 0.05 * beat
        let ventricles = blob(at, 0.02, 0.2, 0.52, 0.6, 0.55, squeeze, taper: true)
        let parts = [
            ventricles,
            blob(at, 0.4, -0.2, 0.25, 0.27, 0, swell, taper: false),
            blob(at, -0.32, -0.24, 0.2, 0.18, 0.3, swell, taper: false),
            tube(at, [(0.08, -0.15), (0.1, -0.62), (-0.12, -0.8), (-0.38, -0.72), (-0.48, -0.42), (-0.5, -0.15)], 0.13, 0.1),
            tube(at, [(-0.06, -0.78), (-0.04, -1.02)], 0.045, 0.035),
            tube(at, [(-0.2, -0.8), (-0.22, -1.02)], 0.045, 0.035),
            tube(at, [(-0.33, -0.74), (-0.4, -0.98)], 0.04, 0.03),
            tube(at, [(-0.12, -0.1), (-0.2, -0.45), (-0.36, -0.55), (-0.7, -0.52)], 0.12, 0.07),
            tube(at, [(-0.22, -0.48), (-0.12, -0.6), (0.0, -0.58)], 0.06, 0.05),
            tube(at, [(0.42, -0.36), (0.44, -1.0)], 0.1, 0.09),
            tube(at, [(0.55, 0.15), (0.62, 0.55)], 0.08, 0.07),
        ]
        var best = parts.max() ?? 0
        if best > 0, ventricles > 0 {
            let coronary = min(
                segment(at, (0.02, -0.08), (-0.12, 0.3)).distance, segment(at, (-0.12, 0.3), (-0.32, 0.62)).distance,
                segment(at, (0.02, -0.08), (0.3, 0.2)).distance, segment(at, (0.3, 0.2), (0.25, 0.55)).distance
            )
            if coronary < 0.03 {
                best = 0.75 + 0.25 * beat
            } else if abs(at.down - (0.02 + 0.25 * at.across * at.across - 0.1 * at.across)) < 0.025, abs(at.across) < 0.5 {
                // The groove between the atria and the ventricles.
                best = 0.1
            }
        }
        return min(1, best * (0.9 + 0.2 * beat))
    }

    /// Lit from the upper left, as a rounded body facing the viewer.
    private static func shade(_ nx: Double, _ ny: Double) -> Double {
        let nz = max(0, 1 - nx * nx - ny * ny).squareRoot()
        return 0.18 + 0.82 * max(0, -0.5 * nx - 0.62 * ny + 0.6 * nz)
    }

    // swiftlint:disable:next function_parameter_count
    private static func blob(
        _ at: Point, _ cx: Double, _ cy: Double, _ across: Double, _ tall: Double, _ turn: Double, _ scale: Double, taper: Bool
    ) -> Double {
        let px = (at.across - cx) / scale
        let py = (at.down - cy) / scale
        let rx = px * cos(turn) + py * sin(turn)
        let ry = -px * sin(turn) + py * cos(turn)
        let height = ry > 0 ? tall * 1.12 : tall
        let width = taper && ry > 0 ? across * (1 - 0.45 * ry / height) : across
        let nx = rx / width
        let ny = ry / height
        guard nx * nx + ny * ny < 1 else { return 0 }
        return shade(nx * cos(turn) - ny * sin(turn), nx * sin(turn) + ny * cos(turn))
    }

    private static func segment(
        _ at: Point, _ from: (Double, Double), _ to: (Double, Double)
    ) -> Segment {
        let dx = to.0 - from.0
        let dy = to.1 - from.1
        let along = max(0, min(1, ((at.across - from.0) * dx + (at.down - from.1) * dy) / (dx * dx + dy * dy)))
        return Segment(distance: hypot(at.across - from.0 - along * dx, at.down - from.1 - along * dy), along: along, dx: dx, dy: dy)
    }

    private static func tube(_ at: Point, _ points: [(Double, Double)], _ startWidth: Double, _ endWidth: Double) -> Double {
        var best = 9.0
        var normal = (0.0, 0.0)
        for index in 0 ..< points.count - 1 {
            let part = segment(at, points[index], points[index + 1])
            let width = startWidth + (endWidth - startWidth) * (Double(index) + part.along) / Double(points.count - 1)
            guard part.distance / width < best else { continue }
            best = part.distance / width
            let length = hypot(part.dx, part.dy)
            let side = ((at.across - points[index].0) * -part.dy / length + (at.down - points[index].1) * part.dx / length) > 0 ? 1.0 : -1
            normal = (-part.dy / length * side * best, part.dx / length * side * best)
        }
        return best < 1 ? shade(normal.0, normal.1) : 0
    }
}
