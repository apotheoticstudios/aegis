import AppKit
import SwiftUI
import Synchronization

/// Character art, the design system's signature: pictures built from the density ramp ` .:-=+*#%@`, ported from its
/// generators. Every shape moves at 12 frames a second, a deliberately terminal-like rate, only while the panel shows.
enum HUDAscii {
    static let ramp = Array(" .:-=+*#%@")
    /// A character cell's width over its height in the art's type (Share Tech Mono, 0.04 em tracking, line height 1).
    static let cellAspect = 0.58

    /// The shapes the screens use, each with its meaning: radar scanning, an eye watching, a helix syncing, a wave
    /// for voice, and an anatomical heart beating for the system's health.
    enum Shape {
        case radar, eye, helix, wave, anatomy
    }

    /// The art as lines, `time` seconds in (0 is the still frame); `grit` breaks the shading up like hand-made art.
    static func art(_ shape: Shape, cols: Int, rows: Int, seed: Double = 1, grit: Double = 0.35, time: Double = 0) -> [String] {
        let aspect = Double(cols) * cellAspect / Double(rows)
        let live = (time * 8).rounded(.down)
        let grid = Grid.cached(cols: cols, rows: rows, seed: seed, grit: grit)
        var line = [UInt8](repeating: 0, count: cols)
        return (0 ..< rows).map { row in
            for col in 0 ..< cols {
                let cell = row * cols + col
                var level = density(shape, grid.across[col], grid.down[row], time, aspect)
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

        private struct Key: Hashable {
            let cols: Int, rows: Int, seed: Double, grit: Double
        }

        private static let cache = Mutex<[Key: Grid]>([:])

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
    static func density(_ shape: Shape, _ across: Double, _ down: Double, _ time: Double, _ aspect: Double) -> Double {
        switch shape {
        case .radar: radar(across, down, time)
        case .eye: HUDEye.density(across, down, time, aspect)
        case .helix: helix(across, down, time)
        case .wave: wave(across, down, time)
        case .anatomy: HUDAnatomy.density(across, down, time)
        }
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
        let moving = animate && HUDPresence.shared.open && !still
        let arriving = arrival.start != nil && HUDPresence.shared.open
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !moving && !arriving)) { context in
            let time = moving ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) : 0
            let lines = HUDAscii.art(shape, cols: cols * detail, rows: rows * detail, seed: seed, grit: grit, time: time)
            let shown = arrival.elapsed(context.date).map {
                HUDMotion.resolve(lines, HUDMotion.progress($0, 0, 1.1), tick: Int($0 * 12), seed: seed)
            } ?? lines
            // Links plug into the whole drawing, not the part resolved so far.
            if hub {
                HUDAsciiText(lines: shown, cols: cols * detail, size: size, tone: tone).hudHub(art: lines)
            } else {
                HUDAsciiText(lines: shown, cols: cols * detail, size: size, tone: tone)
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
        .frame(width: CGFloat(cols) * size * (blocks ? 0.6 : HUDAscii.cellAspect), height: CGFloat(lines.count) * size)
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
