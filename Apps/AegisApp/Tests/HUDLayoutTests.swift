@testable import Aegis
import AegisKit
import Foundation
import XCTest

/// The design system's drawing logic (ADR-0029): where circuit links run, how figures read, and the character art.
final class HUDLayoutTests: XCTestCase {
    /// Left-hand sections are fed from the hub's left, the rest from its right, each ending just outside its title.
    func testLinksRunFromTheHubToEachSectionsTitle() {
        let hub = CGRect(x: 400, y: 100, width: 200, height: 200)
        let left = CGRect(x: 0, y: 40, width: 250, height: 80)
        let right = CGRect(x: 750, y: 300, width: 250, height: 80)
        let layout = HUDLinkLayout(hub: hub, art: [], sections: [right, left], wires: false)
        XCTAssertEqual(layout.links.count, 2)
        let toLeft = layout.links[0]
        XCTAssertEqual(toLeft.end, CGPoint(x: 256, y: 47))
        XCTAssertLessThan(toLeft.start.x, hub.midX)
        let toRight = layout.links[1]
        XCTAssertEqual(toRight.end, CGPoint(x: 744, y: 307))
        XCTAssertGreaterThan(toRight.start.x, hub.midX)
    }

    /// With character art at the hub, a link plugs into the outermost solid character of a row.
    func testLinksPlugIntoHubArt() {
        let art = ["          ", "   @@@@   ", "  @@@@@@  ", "   @@@@   ", "          "]
        let hub = CGRect(x: 100, y: 0, width: 100, height: 50)
        let layout = HUDLinkLayout(hub: hub, art: art, sections: [CGRect(x: 300, y: 0, width: 100, height: 40)], wires: true)
        // One section: the middle solid row, just right of its last solid character (column 8 of 10).
        XCTAssertEqual(layout.links.first?.start, CGPoint(x: 180, y: 25))
    }

    func testFiguresReadAsTheDesignWritesThem() {
        XCTAssertEqual(HUDFormat.bytes(0), "0 B")
        XCTAssertEqual(HUDFormat.bytes(58400, perSecond: true), "58.4 KB/s")
        XCTAssertEqual(HUDFormat.bytes(4_200_000_000), "4.2 GB")
        XCTAssertEqual(HUDFormat.bytes(250_000_000), "250 MB")
        XCTAssertEqual(HUDFormat.percent(0.814), "81%")
        XCTAssertEqual(HUDFormat.percent(1.4), "100%")
        XCTAssertEqual(HUDFormat.uptime(3 * 3600 + 7 * 60), "03:07")
        XCTAssertEqual(HUDFormat.uptime(6 * 86400 + 4 * 3600 + 21 * 60), "6d 04:21")
    }

    /// Every shape draws inside its footprint, from the density ramp only, the same way every time.
    func testCharacterArtStaysOnItsGrid() {
        let ramp = Set(" .:-=+*#%@")
        for shape in [HUDAscii.Shape.radar, .eye, .helix, .wave, .anatomy] {
            let art = HUDAscii.art(shape, cols: 40, rows: 12, time: 1.5)
            XCTAssertEqual(art.count, 12, "\(shape)")
            XCTAssertTrue(art.allSatisfy { $0.count <= 40 && Set($0).isSubset(of: ramp) }, "\(shape)")
            XCTAssertTrue(art.contains { $0.contains { $0 != " " } }, "\(shape) drew nothing")
            XCTAssertEqual(art, HUDAscii.art(shape, cols: 40, rows: 12, time: 1.5), "\(shape)")
        }
    }

    /// The cached, byte-built generator draws exactly what the design system's per-cell generator draws.
    func testCharacterArtMatchesTheReferenceGenerator() {
        for shape in [HUDAscii.Shape.radar, .eye, .helix, .wave, .anatomy] {
            for (cols, rows, seed, grit) in [(68, 24, 1.0, 0.35), (60, 20, 5.0, 0.2), (80, 14, 3.0, 0.5), (1, 1, 1.0, 0.35)] {
                for time in [0, 0.04, 1.5, 6.999, 7.3, 1234.567] {
                    XCTAssertEqual(
                        HUDAscii.art(shape, cols: cols, rows: rows, seed: seed, grit: grit, time: time),
                        Self.referenceArt(shape, cols: cols, rows: rows, seed: seed, grit: grit, time: time),
                        "\(shape) \(cols)×\(rows) at \(time)"
                    )
                }
            }
        }
    }

    /// The generator as first ported: every cell's place, grain and gaps worked out each frame.
    private static func referenceArt(_ shape: HUDAscii.Shape, cols: Int, rows: Int, seed: Double, grit: Double, time: Double) -> [String] {
        let aspect = Double(cols) * HUDAscii.cellAspect / Double(rows)
        let live = (time * 8).rounded(.down)
        return (0 ..< rows).map { row in
            String((0 ..< cols).map { col in
                let across = (Double(col) + 0.5) / Double(cols) * 2 - 1
                let down = (Double(row) + 0.5) / Double(rows) * 2 - 1
                var level = HUDAscii.density(shape, across, down, time, aspect)
                if level > 0 {
                    level += (HUDAscii.hash(Double(col), Double(row), seed) - 0.5) * grit
                    if HUDAscii.hash(Double(row), Double(col), seed + 3) < grit * 0.18 {
                        level = 0
                    }
                    if time > 0 {
                        level += (HUDAscii.hash(Double(col), Double(row), seed + live) - 0.5) * 0.08
                    }
                }
                return HUDAscii.ramp[Int(min(max(level, 0), 0.999) * Double(HUDAscii.ramp.count))]
            }).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
    }

    /// The name is cut from Xirod at the asked height; block banners add a shadow row.
    func testBannerIsTheNameInCharacters() {
        let banner = HUDBanner.lines("Aegis", rows: 10)
        XCTAssertEqual(banner.count, 10)
        XCTAssertGreaterThan(banner.map(\.count).max() ?? 0, 60)
        XCTAssertTrue(banner.joined().contains("@"))
        let block = HUDBanner.lines("Aegis", rows: 5, block: true)
        XCTAssertEqual(block.count, 6)
        XCTAssertTrue(block.joined().contains("█"))
    }

    @MainActor
    func testHourlyCountsAddUpBySource() {
        let presence = ActivityPresence()
        XCTAssertEqual(presence.total, [])
        var counts = Array(repeating: 0, count: 24)
        counts[23] = 3
        presence.latest = HourlyActivity(start: Date(timeIntervalSince1970: 0), counts: [.email: counts, .imessage: counts])
        XCTAssertEqual(presence.hours([.email]).last, 3)
        XCTAssertEqual(presence.total.last, 6)
        XCTAssertEqual(presence.total.reduce(0, +), 6)
    }

    /// COMMS counts today from midnight: the day's last hours, one per hour so far.
    func testTodayIsTheHoursSinceMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 30)))
        let day = (0 ..< 24).map(Double.init)
        XCTAssertEqual(CommsScreen.today(day, now: morning, calendar: calendar), Array(day.suffix(10)))
    }

    /// The sample's day has the same shape as AegisCore's answer: 24 hours for each source, quiet overnight.
    func testSampleActivityIsADayOfCounts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12, minute: 15)))
        let day = SampleCoreService.activity(hours: 24, now: now, calendar: calendar)
        XCTAssertEqual(day.start, calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 13)))
        XCTAssertEqual(Set(day.counts.values.map(\.count)), [24])
        XCTAssertEqual(day.counts[.email]?[15], 0, "04:00 is quiet")
    }
}
