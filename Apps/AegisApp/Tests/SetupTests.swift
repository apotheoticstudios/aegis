@testable import Aegis
import AegisKit
import SwiftUI
import XCTest

/// The setup wizard's window side (#26), with a synthetic Mac and a temporary file: never the owner's setup.
@MainActor
final class SetupTests: XCTestCase {
    static let sampleMac = MacProfile(
        model: "MacBook Air (13-inch, M4, 2025)", chip: "Apple M4", memoryBytes: 24 << 30,
        diskTotalBytes: 994_000_000_000, diskFreeBytes: 312_000_000_000, systemVersion: "26.1",
        appleIntelligence: true, isLaptop: true
    )

    func testDetectsThisMac() {
        let mac = MacProfile.detect()
        XCTAssertEqual(mac.memoryBytes, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(mac.diskTotalBytes, mac.diskFreeBytes)
        XCTAssertFalse(mac.model.isEmpty)
        XCTAssertFalse(mac.chip.isEmpty)
        XCTAssertTrue(mac.systemVersion.hasPrefix("\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"))
    }

    func testSavesEachChangeAndResumesOnTheBuiltScreens() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let setup = SetupModel(file: SetupFile(url: url), mac: Self.sampleMac)
        XCTAssertEqual(setup.wizard.steps, SetupModel.built)
        setup.wizard.next()
        setup.wizard.next()
        setup.wizard.storageGB = 60

        var later = Self.sampleMac
        later.diskFreeBytes = 200_000_000_000
        let resumed = SetupModel(file: SetupFile(url: url), mac: later)
        XCTAssertEqual(resumed.wizard.current, .storage)
        XCTAssertEqual(resumed.wizard.storageGB, 60)
        XCTAssertEqual(resumed.wizard.mac.diskFreeBytes, 200_000_000_000, "free space is read again")
        XCTAssertEqual(resumed.wizard.steps, SetupModel.built)
    }

    func testBriefTimeReadsInTheMacsFormat() {
        let shown = SetupText.time(6 * 60 + 30)
        XCTAssertTrue(shown.contains("6") && shown.contains("30"), shown)
        XCTAssertEqual(SetupText.model(24 << 30), "Qwen3.5-9B")
        XCTAssertEqual(SetupText.model(16 << 30), "Qwen3.5-4B")
    }
}
