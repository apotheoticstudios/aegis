@testable import Aegis
import AppKit
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
}
