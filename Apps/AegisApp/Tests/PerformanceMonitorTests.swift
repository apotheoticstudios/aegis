@testable import Aegis
import XCTest

/// The Performance Monitor addon: "why is my Mac slow?" from one reading, and apps counted with their helpers.
/// Synthetic readings only.
final class PerformanceMonitorTests: XCTestCase {
    private let gigabyte: UInt64 = 1_073_741_824

    private func reading(cpu: Double, memory: Double, swap: UInt64 = 0) -> SystemReading {
        var reading = SystemReading()
        reading.cores = (1 ... 8).map { .init(label: "P\($0)", load: cpu) }
        reading.cpu = cpu
        reading.memoryTotal = 16 * gigabyte
        reading.memoryUsed = UInt64(memory * 16) * gigabyte
        reading.swapUsed = swap
        reading.diskTotal = 500 * gigabyte
        reading.diskUsed = 200 * gigabyte
        return reading
    }

    func testItRecognisesTheQuestion() {
        for question in ["Why is my Mac so slow?", "my mac is laggy", "what's slowing down my computer", "why is everything so slow"] {
            XCTAssertTrue(SystemReading.asksWhySlow(question), question)
        }
        for other in ["what's on today", "remind me to buy milk", "is the train slow"] {
            XCTAssertFalse(SystemReading.asksWhySlow(other), other)
        }
    }

    func testItNamesTheAppAndHowToQuitIt() {
        var busy = reading(cpu: 0.8, memory: 0.5)
        busy.processes = [
            .init(name: "AegisCore", cpu: 0.1, memory: gigabyte, aegis: true),
            .init(name: "Example Editor", cpu: 4, memory: 3 * gigabyte, aegis: false, app: true),
            .init(name: "kernel_task", cpu: 0.5, memory: gigabyte, aegis: false),
        ]
        XCTAssertEqual(
            busy.diagnosis,
            "Your Mac is slow because Example Editor is using 50% of the processor. "
                + "Say “quit Example Editor” to close it; it will ask about anything unsaved."
        )
    }

    func testMemoryNamesTheHeaviestAndANonAppIsNeverOfferedToQuit() {
        var full = reading(cpu: 0.2, memory: 0.94, swap: 3 * gigabyte)
        full.heaviest = .init(name: "WindowServer", cpu: 0.1, memory: 2 * gigabyte, aegis: false)
        full.thermal = .serious
        XCTAssertEqual(
            full.diagnosis,
            "Your Mac is slow because it's running hot, so macOS is slowing it down to cool off and memory is 94% full, "
                + "with WindowServer using 2.0 GB."
        )
    }

    func testACalmMacSaysSo() {
        XCTAssertTrue(reading(cpu: 0.1, memory: 0.5).diagnosis.hasPrefix("Nothing is straining your Mac right now"))
    }

    func testHelpersCountAsTheirApp() {
        XCTAssertEqual(
            SystemReader.appName("/Applications/Example Browser.app/Contents/Frameworks/Helper (Renderer).app/Contents/MacOS/Helper"),
            "Example Browser"
        )
        XCTAssertNil(SystemReader.appName("/usr/libexec/exampled"))
    }
}
