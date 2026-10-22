@testable import Aegis
import Foundation
import XCTest

/// The design's motion (Motion.md) as pure functions of time: its curves, the build order and each stepped move.
final class HUDMotionTests: XCTestCase {
    /// The ease curves read as CSS draws them: standard and enter decelerate hard, ambient is symmetric.
    func testCurvesMatchTheirCubicBeziers() {
        for curve in [HUDMotion.standard, HUDMotion.enter, HUDMotion.ambient, HUDMotion.linear] {
            XCTAssertEqual(curve(0), 0)
            XCTAssertEqual(curve(1), 1)
            XCTAssertEqual(curve(-1), 0)
            XCTAssertEqual(curve(2), 1)
        }
        XCTAssertEqual(HUDMotion.standard(0.5), 0.8778, accuracy: 0.0005)
        XCTAssertEqual(HUDMotion.enter(0.25), 0.8315, accuracy: 0.0005)
        XCTAssertEqual(HUDMotion.ambient(0.3) + HUDMotion.ambient(0.7), 1, accuracy: 1e-6)
        XCTAssertEqual(HUDMotion.linear(0.37), 0.37, accuracy: 1e-6)
    }

    /// Sections arrive from 620 ms, 110 ms apart down each column, so both side columns arrive in pairs; staggered
    /// siblings stop waiting after the twelfth.
    func testBuildOrder() {
        XCTAssertEqual(HUDMotion.section(0), 0.62, accuracy: 1e-9)
        XCTAssertEqual(HUDMotion.section(2), 0.84, accuracy: 1e-9)
        XCTAssertEqual(HUDMotion.stagger(3, 0.04), 0.12, accuracy: 1e-9)
        XCTAssertEqual(HUDMotion.stagger(40, 0.04), HUDMotion.stagger(12, 0.04))
        XCTAssertLessThan(HUDMotion.section(3) + 0.2 + 1.1, HUDMotion.built, "the last section's art resolves in time")
    }

    /// A move waits out its delay, runs its duration, then holds; once built everything shows settled.
    func testProgressThroughAMove() {
        XCTAssertEqual(HUDMotion.progress(0.1, 0.2, 0.5), 0)
        XCTAssertEqual(HUDMotion.progress(0.45, 0.2, 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(HUDMotion.progress(3, 0.2, 0.5), 1)
        XCTAssertEqual(HUDMotion.progress(nil, 0.2, 0.5), 1)
        XCTAssertEqual(HUDMotion.segment(0.69, 0.38, 1), 0.5, accuracy: 1e-9)
    }

    /// Text steps: the flicker holds each keyframe, a line types in 24 steps, the caret blinks on and off.
    func testStepsHoldTheirValues() {
        XCTAssertEqual(HUDMotion.flicker(0), 0)
        XCTAssertEqual(HUDMotion.flicker(0.19), 0)
        XCTAssertEqual(HUDMotion.flicker(0.25), 1)
        XCTAssertEqual(HUDMotion.flicker(0.4), 0.15)
        XCTAssertEqual(HUDMotion.flicker(0.5), 0.9)
        XCTAssertEqual(HUDMotion.flicker(0.6), 0.35)
        XCTAssertEqual(HUDMotion.flicker(1), 1)
        XCTAssertEqual(HUDMotion.typed(0.04), 0)
        XCTAssertEqual(HUDMotion.typed(0.5), 0.5)
        XCTAssertEqual(HUDMotion.typed(0.99), 23 / 24)
        XCTAssertEqual(HUDMotion.typed(1), 1)
        XCTAssertTrue(HUDMotion.blink(0.2))
        XCTAssertFalse(HUDMotion.blink(0.7))
        XCTAssertTrue(HUDMotion.blink(1.1))
        XCTAssertFalse(HUDMotion.blink(0.5, period: 0.9))
    }

    /// The live dot breathes 1 → 0.55 → 1 over 3.2 s.
    func testBreath() {
        XCTAssertEqual(HUDMotion.breathe(0), 1, accuracy: 1e-9)
        XCTAssertEqual(HUDMotion.breathe(1.6), 0.55, accuracy: 1e-9)
        XCTAssertEqual(HUDMotion.breathe(3.2), 1, accuracy: 1e-6)
        XCTAssertEqual(HUDMotion.breathe(0.8), HUDMotion.breathe(2.4), accuracy: 1e-9)
    }

    /// A scrambling value keeps its shape: the resolved part reads true, letters stay letters and digits digits, and
    /// everything else holds still.
    func testScrambleKeepsTheValuesShape() {
        let value = "6d 04:21"
        XCTAssertEqual(HUDMotion.scramble(value, 1, tick: 3), value)
        for tick in 0 ..< 20 {
            let shown = Array(HUDMotion.scramble(value, 0.25, tick: tick))
            XCTAssertEqual(shown.count, value.count)
            XCTAssertEqual(String(shown.prefix(2)), "6d")
            for (real, drawn) in zip(value, shown) {
                XCTAssertEqual(real.isNumber, drawn.isNumber)
                XCTAssertEqual(real.isLowercase, drawn.isLowercase)
                if !real.isLetter, !real.isNumber {
                    XCTAssertEqual(real, drawn)
                }
            }
        }
        XCTAssertNotEqual(HUDMotion.scramble("CPU 100", 0, tick: 1), HUDMotion.scramble("CPU 100", 0, tick: 2))
    }

    /// Art resolves top to bottom: blank before, rows above the front read true, noise only from the density ramp.
    func testArtResolvesTopToBottom() {
        let art = Array(repeating: "  @@%%##**  ", count: 12)
        XCTAssertEqual(HUDMotion.resolve(art, 0, tick: 0), Array(repeating: "", count: 12))
        XCTAssertEqual(HUDMotion.resolve(art, 1, tick: 0), art)
        let half = HUDMotion.resolve(art, 0.5, tick: 4)
        XCTAssertEqual(half.first, art.first)
        XCTAssertEqual(half.last, "")
        let ramp = Set(HUDAscii.ramp)
        XCTAssertTrue(half.allSatisfy { Set($0).isSubset(of: ramp) })
    }

    /// TypeText holds the untyped rest in place, and the underscore cursor only ever stands in for a character.
    func testTypingHoldsTheLineInPlace() {
        let line = HUDMotion.typing("Three new messages", 0.3, cursor: true)
        XCTAssertEqual(line.typed, "Three")
        XCTAssertEqual(line.cursor, "")
        XCTAssertEqual(line.rest, " new messages")
        let mid = HUDMotion.typing("Three new messages", 0.2, cursor: true)
        XCTAssertEqual(mid.typed + mid.cursor + mid.rest, "Thr_e new messages")
        XCTAssertEqual(HUDMotion.typing("Three", 0.2, cursor: false).cursor, "")
        XCTAssertEqual(HUDMotion.typing("Three", 0, cursor: true).cursor, "", "no cursor before typing starts")
        XCTAssertEqual(HUDMotion.typing("Three", 1, cursor: true).typed, "Three")
    }

    /// The shell opens from a point to a line across the middle, then into the box.
    func testShellOpensFromALine() {
        let box = CGRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertEqual(HUDOpening(progress: 0).path(in: box).boundingRect, CGRect(x: 200, y: 99, width: 0, height: 2))
        XCTAssertEqual(HUDOpening(progress: 0.38).path(in: box).boundingRect, CGRect(x: 0, y: 99, width: 400, height: 2))
        XCTAssertTrue(HUDOpening(progress: 1).path(in: box).boundingRect.contains(box))
    }

    /// The build-on plays once per launch.
    @MainActor
    func testBuildPlaysOnce() {
        let build = HUDBuild()
        XCTAssertNil(build.start)
        build.play()
        let start = build.start
        XCTAssertNotNil(start)
        build.play()
        XCTAssertEqual(build.start, start)
        XCTAssertTrue(build.played)
    }
}
