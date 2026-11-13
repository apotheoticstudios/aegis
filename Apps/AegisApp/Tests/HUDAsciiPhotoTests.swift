@testable import Aegis
import Foundation
import XCTest

/// The design's photo shapes and `reform` (#186).
final class HUDAsciiPhotoTests: XCTestCase {
    func testEveryPhotoLoadsAtItsSize() {
        let sizes = [
            "satellite": (140, 150), "laptop": (150, 150), "house": (150, 84), "vault": (150, 150), "lighthouse": (92, 150),
            "lock": (150, 150), "shutter": (150, 150), "bulb": (150, 150), "gears": (104, 150),
        ]
        XCTAssertEqual(Set(HUDPhoto.maps.keys), Set(sizes.keys))
        for (name, size) in sizes {
            let map = HUDPhoto.maps[name]
            XCTAssertEqual(map?.width, size.0, name)
            XCTAssertEqual(map?.height, size.1, name)
        }
    }

    func testUnpacksTheDesignsEncoding() {
        // "B" is 1, "P" 15, "Q" 16 (the moving bit); "!C" is a run of three empty cells.
        XCTAssertEqual(HUDPhoto.unpack("BP!CQ", count: 6), [1, 15, 0, 0, 0, 16])
        XCTAssertEqual(HUDPhoto.unpack("BP", count: 3), [], "too short")
        XCTAssertEqual(HUDPhoto.unpack("BP?", count: 3), [], "not a digit")
    }

    func testAMissingFileDrawsNothing() {
        XCTAssertTrue(HUDPhoto.load(nil).isEmpty)
        XCTAssertTrue(HUDPhoto.load(URL(fileURLWithPath: "/nonexistent/ascii-photos.json")).isEmpty)
    }

    /// The same characters the design's own generator draws (60 × 30, seed 1, grit 0.35), still and 3.7 s in,
    /// as FNV-1a checksums of its output.
    func testDrawsExactlyWhatTheDesignDraws() {
        let expected: [(HUDAscii.Shape, UInt64, UInt64)] = [
            (.satellite, 0xB4E0_91E2_9DB8_F569, 0x723D_AF29_E73E_ACF3),
            (.laptop, 0xB698_CBBF_FE19_7DAC, 0xD764_1B88_5C63_FBAF),
            (.house, 0x3180_4C97_7CB9_6352, 0xD2A8_63FF_1A1B_699C),
            (.vault, 0xA024_6DB4_A6E8_C67C, 0x91CA_8B9F_E33B_FA2C),
            (.lighthouse, 0xF5F8_97F0_AD4E_9CB5, 0x78A2_B62E_C2E8_5BB1),
            (.lock, 0x6288_ED5B_9D27_FA2B, 0xE894_FFF3_9CA7_D56D),
            (.shutter, 0x8055_E0F2_E54A_294B, 0x2B35_E84B_6940_6EFE),
            (.bulb, 0x5017_7BAB_2DC0_55CA, 0x3306_A1FD_85B7_2C3B),
            (.gears, 0x562F_0F60_5661_ADA1, 0x1538_BD60_4837_A4FE),
            (.reform, 0xC2BA_CA5E_ADF7_E1CF, 0x5C47_2364_9B73_972A),
        ]
        for (shape, still, moving) in expected {
            XCTAssertEqual(checksum(HUDAscii.art(shape, cols: 60, rows: 30, time: 0)), still, "\(shape) still")
            XCTAssertEqual(checksum(HUDAscii.art(shape, cols: 60, rows: 30, time: 3.7)), moving, "\(shape) moving")
        }
    }

    private func checksum(_ lines: [String]) -> UInt64 {
        lines.joined(separator: "\n").utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
    }
}
