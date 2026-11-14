@testable import Aegis
import AppKit
import SwiftUI
import XCTest

/// Character art drawn straight from the face's glyphs (#192): what it draws itself, and what it leaves to text.
final class HUDGlyphFaceTests: XCTestCase {
    func testTheFaceDrawsTheRampAndLeavesTheRestToText() throws {
        let face = HUDGlyphFace.face(blocks: false, size: 12)
        XCTAssertTrue(face === HUDGlyphFace.face(blocks: false, size: 12), "one face per size, shared")
        XCTAssertFalse(face === HUDGlyphFace.face(blocks: true, size: 12))
        XCTAssertGreaterThan(face.cell, 6, "the advance plus the design's tracking")
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 64, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        XCTAssertTrue(face.draw(" .:-=+*#%@", baseline: 12, in: context))
        // Characters the face lacks, or that take two UTF-16 units, are set as text instead.
        XCTAssertFalse(face.draw("漢", baseline: 12, in: context))
        XCTAssertFalse(face.draw("@🙂", baseline: 12, in: context))
        XCTAssertTrue(HUDGlyphFace.face(blocks: true, size: 8).draw("█▓▒░", baseline: 8, in: context))
        // Measured once, then remembered.
        var measured = 0
        XCTAssertEqual(face.natural(cols: 7) { measured += 1; return CGFloat($0) * 7 }, 49)
        XCTAssertEqual(face.natural(cols: 7) { _ in measured += 1; return 0 }, 49)
        XCTAssertEqual(measured, 1)
    }

    /// The glyph drawing matches setting every row as text, as HUDAsciiText did before (#192): pixel for pixel, at the
    /// art's and the banners' sizes, and below 3 points where it is still set as text.
    @MainActor
    func testGlyphsLandExactlyWhereTextDid() throws {
        let globe = HUDAscii.art(.globe, cols: 40, rows: 20, grit: 0.22)
        let banner = HUDBanner.lines("Aegis", rows: 10)
        for (lines, cols, size) in [
            (globe, 40, CGFloat(6)),
            (globe, 40, 12),
            (banner, banner.map(\.count).max() ?? 0, 9),
            (banner, 30, 2.4),
        ] {
            let drawn = try pixels(HUDAsciiText(lines: lines, cols: cols, size: size, tone: HUD.primary, aspect: HUDAscii.artAspect))
            let text = try pixels(TextArt(lines: lines, cols: cols, size: size))
            XCTAssertEqual(drawn, text, "size \(size)")
            XCTAssertTrue(drawn.contains { $0 != 0 }, "something was drawn at size \(size)")
        }
    }

    @MainActor
    private func pixels(_ view: some View) throws -> [UInt8] {
        let host = NSHostingView(rootView: view.environment(\.hudTheme, .arc).background(Color.black))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Array(UnsafeBufferPointer(start: rep.bitmapData, count: rep.bytesPerRow * rep.pixelsHigh))
    }
}

/// HUDAsciiText as it was before #192: every row set as text. The reference the glyph drawing must match.
private struct TextArt: View {
    let lines: [String]
    let cols: Int
    let size: CGFloat
    @Environment(\.hudTheme) private var theme

    var body: some View {
        Canvas { context, canvas in
            let natural = context.resolve(styled(String(repeating: "@", count: max(cols, 1))))
                .measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width
            if natural > 0 {
                context.scaleBy(x: canvas.width / natural, y: 1)
            }
            for (row, line) in lines.enumerated() where !line.isEmpty {
                context.draw(styled(line), at: CGPoint(x: 0, y: CGFloat(row) * size), anchor: .topLeading)
            }
        }
        .frame(width: CGFloat(cols) * size * HUDAscii.artAspect, height: CGFloat(lines.count) * size)
        .shadow(color: theme.color(.primary).opacity(0.55), radius: 3)
    }

    private func styled(_ line: String) -> Text {
        Text(line).font(.custom(HUDType.ascii.fontName, size: size)).tracking(size * 0.04).foregroundStyle(theme.color(.primary))
    }
}
