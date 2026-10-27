@testable import Aegis
import Foundation
import XCTest

final class HUDAsciiShapesTests: XCTestCase {
    func testNewShapesRenderStillAndMovingFrames() {
        let shapes: [HUDAscii.Shape] = [
            .orb, .reticle, .heart, .globe, .tunnel, .planet, .storm, .sun, .moon,
            .chip, .rain, .city, .blackhole, .floorplan, .torus, .tesseract, .atom,
        ]
        let ramp = Set(" .:-=+*#%@")
        for shape in shapes {
            let still = HUDAscii.art(shape, cols: 40, rows: 20, time: 0)
            for time in [0.0, 3.7] {
                let lines = HUDAscii.art(shape, cols: 40, rows: 20, time: time)
                let context = "\(shape) at \(time)"
                XCTAssertEqual(lines.count, 20, context)
                XCTAssertTrue(lines.contains { $0.contains { $0 != " " } }, context)
                XCTAssertTrue(lines.allSatisfy { Set($0).isSubset(of: ramp) && $0.count <= 40 }, context)
            }
            XCTAssertEqual(HUDAscii.art(shape, cols: 40, rows: 20, time: 0), still, "\(shape) after advancing time")
        }
    }

    func testSphereLightingAndGrid() {
        // At t=0 the orb light is (-0.5, -0.6, 0.62): centre = 0.15 + 0.9*0.62.
        XCTAssertEqual(HUDAscii.density(.orb, 0, 0, 0, 1), 0.708, accuracy: 1e-12)
        // At (-0.6, 0), z=0.8: 0.15 + 0.9*(0.3 + 0.496).
        XCTAssertEqual(HUDAscii.density(.orb, -0.6, 0, 0, 1), 0.8664, accuracy: 1e-12)
        // After half a light orbit, lx=+0.5: 0.15 + 0.9*(-0.3 + 0.496).
        XCTAssertEqual(HUDAscii.density(.orb, -0.6, 0, .pi / 0.6, 1), 0.3264, accuracy: 1e-12)
        // The globe's equator is a grid line: 0.55 + z*0.4, with z=1 and z=0.8.
        XCTAssertEqual(HUDAscii.density(.globe, 0, 0, 0, 1), 0.95, accuracy: 1e-12)
        XCTAssertEqual(HUDAscii.density(.globe, 0.6, 0, 3.7, 1), 0.87, accuracy: 1e-12)
        XCTAssertEqual(HUDAscii.density(.orb, 1, 1, 0, 1), 0)
    }

    func testReticleTunnelAndSun() {
        // The reticle centre is 0.6 + 0.4*abs(sin(3*t)); its crosshair is 0.75.
        XCTAssertEqual(HUDAscii.density(.reticle, 0, 0, 0, 1), 0.6, accuracy: 1e-12)
        XCTAssertEqual(HUDAscii.density(.reticle, 0, 0, .pi / 6, 1), 1, accuracy: 1e-12)
        XCTAssertEqual(HUDAscii.density(.reticle, 0.5, 0, 0, 1), 0.75, accuracy: 1e-12)
        // At r=1, depth=0: t=0 lights a ring (0.35+0.6), t=0.2 wraps -0.3 to 0.7, leaving the rim.
        XCTAssertEqual(HUDAscii.density(.tunnel, 1, 0, 0, 1), 0.95, accuracy: 1e-12)
        XCTAssertEqual(HUDAscii.density(.tunnel, 1, 0, 0.2, 1), 0.7, accuracy: 1e-12)
        XCTAssertEqual(HUDAscii.density(.tunnel, 0, 0, 3.7, 1), 1, accuracy: 1e-12)
        // Sun at half its disc radius: 0.75 + 0.25*(1-0.18/0.36); the surrounding ring is 0.3.
        XCTAssertEqual(HUDAscii.density(.sun, 0.18, 0, 3.7, 1), 0.875, accuracy: 1e-12)
        XCTAssertEqual(HUDAscii.density(.sun, 0.4, 0, 0, 1), 0.3, accuracy: 1e-12)
    }

    func testPlanetBlackholeAndAtom() {
        // Planet centre: z=1, band=0, so (0.3+0.7*0.6)*0.7.
        XCTAssertEqual(HUDAscii.density(.planet, 0, 0, 0, 1), 0.504, accuracy: 1e-12)
        // At the upper accretion arc r=0.365, sin(6*a)=0: 0.5*(1-0.095/0.19)+0.15*0.5.
        XCTAssertEqual(HUDAscii.density(.blackhole, 0, -0.365, 0, 1), 0.325, accuracy: 1e-12)
        XCTAssertEqual(HUDAscii.density(.blackhole, 0, -0.265, 3.7, 1), 1, accuracy: 1e-12) // Photon ring.
        XCTAssertEqual(HUDAscii.density(.blackhole, 0, 0, 3.7, 1), 0) // Shadow.
        // At t=0 the atom nucleus is 0.6; the first electron is at the rotated ellipse's (0.92, 0).
        XCTAssertEqual(HUDAscii.density(.atom, 0, 0, 0, 1), 0.6, accuracy: 1e-12)
        XCTAssertEqual(HUDAscii.density(.atom, 0.92 * cos(0.3), 0.92 * sin(0.3), 0, 1), 1, accuracy: 1e-12)
    }

    func testAspectFittingAndFloorplanDoors() {
        // A wide footprint doubles u; a tall footprint doubles v. The orb's z is 0.8 in both.
        XCTAssertEqual(HUDAscii.density(.orb, -0.3, 0, 0, 2), 0.8664, accuracy: 1e-12)
        XCTAssertEqual(HUDAscii.density(.orb, 0, -0.3, 0, 0.5), 0.9204, accuracy: 1e-12)
        // Floorplan ar=1 gives k=1/16: (u=0,v=-0.28125) maps to the lit room centre (16,4.5).
        XCTAssertEqual(HUDAscii.density(.floorplan, 0, -0.28125, 0, 1), 0.42, accuracy: 1e-12)
        // With ar=2, k=1/9, the same room centre has v=-0.5; at t=pi/10 it gains 0.02*sin(pi/2).
        XCTAssertEqual(HUDAscii.density(.floorplan, 0, -0.5, .pi / 10, 2), 0.44, accuracy: 1e-12)
        // Garage (0,5) is dashed: phase 7.5-4*t is 7.1 at t=0.1 and 6.7 at t=0.2.
        XCTAssertEqual(HUDAscii.density(.floorplan, -1, -0.25, 0, 1), 0.6, accuracy: 1e-12)
        XCTAssertEqual(HUDAscii.density(.floorplan, -1, -0.25, 0.1, 1), 0.85, accuracy: 1e-12)
        XCTAssertEqual(HUDAscii.density(.floorplan, -1, -0.25, 0.2, 1), 0.2, accuracy: 1e-12)
        XCTAssertEqual(HUDAscii.density(.floorplan, 0.3125, 0.5625, 0, 1), 0.55, accuracy: 1e-12) // Shut door (21,18).
        XCTAssertEqual(HUDAscii.density(.city, 0.2, 0.4, 3.7, 2), HUDAscii.density(.city, 0.2, 0.4, 3.7, 0.5))
    }

    func testRainReceivesCellCoordinates() {
        // Column 1 at t=0: speed=7.10570906799, length=12.92453397606, head=9.79899982320 for 20 rows.
        // Row 9 is the head; row 7 is 0.85*(1-2.79899982320/12.92453397606)+0.08.
        XCTAssertEqual(HUDAscii.density(.rain, 0, 0, 0, 1, column: 1, row: 9, rows: 20), 1)
        XCTAssertEqual(HUDAscii.density(.rain, 0, 0, 0, 1, column: 1, row: 7, rows: 20), 0.745919873465, accuracy: 1e-8)
        // Column 0 at t=3.7: head=7.05207363519, length=8.04985089604, so row 5 has back=2.05207363519.
        XCTAssertEqual(HUDAscii.density(.rain, 0, 0, 3.7, 1, column: 0, row: 5, rows: 20), 0.713317403957, accuracy: 1e-8)
        XCTAssertEqual(HUDAscii.density(.rain, 0, 0, 0, 1), 0)
        let art = HUDAscii.art(.rain, cols: 40, rows: 20, grit: 0, time: 0)
        XCTAssertEqual(art[9].dropFirst().first, "@")
        XCTAssertEqual(art[7].dropFirst().first, "#")
    }

    func testCellMetadataDoesNotChangeExistingShapes() {
        let shapes: [HUDAscii.Shape] = [
            .radar, .eye, .helix, .wave, .anatomy, .galaxy, .cube, .shield, .hourglass, .fingerprint, .spectrum, .horizon,
        ]
        for shape in shapes {
            for time in [0.0, 3.7] {
                for aspect in [0.5, 2.0] {
                    XCTAssertEqual(
                        HUDAscii.density(shape, 0.2, -0.3, time, aspect),
                        HUDAscii.density(shape, 0.2, -0.3, time, aspect, column: 24, row: 7, rows: 20),
                        "\(shape)"
                    )
                }
            }
        }
    }
}
