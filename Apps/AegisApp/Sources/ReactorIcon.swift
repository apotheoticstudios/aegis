import AppKit

/// The menu bar's arc reactor (design: "an arc reactor-style icon, the only thing visible while Aegis
/// runs"). A template image, so macOS tints it for light and dark menu bars. The core fills in when
/// something urgent waits (#169); otherwise it is a ring.
enum ReactorIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image(glowing: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let outer = NSBezierPath(ovalIn: rect.insetBy(dx: 1.2, dy: 1.2))
            outer.lineWidth = 1.3
            outer.stroke()
            // Ten coil segments between the core and the outer ring.
            for index in 0 ..< 10 {
                let angle = CGFloat(index) * .pi / 5 + .pi / 10
                let segment = NSBezierPath()
                segment.lineWidth = 1.5
                segment.lineCapStyle = .butt
                segment.move(to: point(center, radius: 4.4, angle: angle))
                segment.line(to: point(center, radius: 6.6, angle: angle))
                segment.stroke()
            }
            let core = NSBezierPath(ovalIn: NSRect(x: center.x - 2.8, y: center.y - 2.8, width: 5.6, height: 5.6))
            if glowing {
                core.fill()
            } else {
                core.lineWidth = 1.2
                core.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = glowing ? "Aegis: something urgent waits" : "Aegis"
        return image
    }

    private static func point(_ center: NSPoint, radius: CGFloat, angle: CGFloat) -> NSPoint {
        NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }
}
