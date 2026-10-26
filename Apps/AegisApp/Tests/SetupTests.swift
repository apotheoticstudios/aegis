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
        XCTAssertEqual(setup.wizard.steps, SetupStep.offered)
        setup.wizard.next()
        setup.wizard.next()
        setup.wizard.storageGB = 60

        var later = Self.sampleMac
        later.diskFreeBytes = 200_000_000_000
        let resumed = SetupModel(file: SetupFile(url: url), mac: later)
        XCTAssertEqual(resumed.wizard.current, .storage)
        XCTAssertEqual(resumed.wizard.storageGB, 60)
        XCTAssertEqual(resumed.wizard.mac.diskFreeBytes, 200_000_000_000, "free space is read again")
        XCTAssertEqual(resumed.wizard.steps, SetupStep.offered)
    }

    func testChecksAFileBySHA256() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("part-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try ModelDownloads.sha256(of: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// Opt-in, as it fetches the 134 MB meaning model from Hugging Face: `TEST_RUNNER_AEGIS_DOWNLOAD_CHECK=1`.
    func testDownloadsAndChecksTheMeaningModel() async throws {
        guard ProcessInfo.processInfo.environment["AEGIS_DOWNLOAD_CHECK"] != nil else {
            throw XCTSkip("Set AEGIS_DOWNLOAD_CHECK to download the meaning model into a temporary folder.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let downloads = ModelDownloads()
        let fetched = await downloads.fetch([.meaning], into: folder)
        XCTAssertTrue(fetched, "\(downloads.state)")
        XCTAssertEqual(downloads.received, ModelFiles.meaning.bytes)
        for file in ModelFiles.meaning.files {
            let url = folder.appendingPathComponent("bge-small-en-v1.5").appendingPathComponent(file.path)
            XCTAssertEqual(try ModelDownloads.sha256(of: url), file.sha256, file.path)
        }
        // A second run finds everything in place and fetches nothing.
        let again = await downloads.fetch([.meaning], into: folder)
        XCTAssertTrue(again)
    }

    /// The design's extra choices keep only what the owner changed, and survive a restart of setup.
    func testChoicesKeepOnlyChangesAndResume() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let setup = SetupModel(file: SetupFile(url: url), mac: Self.sampleMac)
        let quiet = setup.option("quiet", "focus")
        let photos = setup.flag("source.photos", false)
        let apps = setup.list("neverApps", ["1Password", "Banking apps"])
        let formality = setup.number("tone.formality", 6)
        XCTAssertEqual(quiet.wrappedValue, "focus")
        XCTAssertFalse(photos.wrappedValue)
        XCTAssertEqual(apps.wrappedValue, ["1Password", "Banking apps"])
        XCTAssertEqual(formality.wrappedValue, 6)
        XCTAssertNil(setup.wizard.answers.options, "nothing changed yet")

        quiet.wrappedValue = "hours"
        photos.wrappedValue = true
        apps.wrappedValue.removeAll { $0 == "1Password" }
        apps.wrappedValue.append("Notes")
        formality.wrappedValue = 9
        XCTAssertEqual(setup.wizard.answers.options, [
            "quiet": "hours", "source.photos": "on", "neverApps": "Banking apps\nNotes", "tone.formality": "9",
        ])

        let resumed = SetupModel(file: SetupFile(url: url), mac: Self.sampleMac)
        XCTAssertEqual(resumed.option("quiet", "focus").wrappedValue, "hours")
        XCTAssertTrue(resumed.flag("source.photos", false).wrappedValue)
        XCTAssertEqual(resumed.list("neverApps", ["1Password", "Banking apps"]).wrappedValue, ["Banking apps", "Notes"])
        XCTAssertEqual(resumed.number("tone.formality", 6).wrappedValue, 9)

        // Back to the recommended answer: the key goes, so a later change to the recommendation applies.
        resumed.option("quiet", "focus").wrappedValue = "focus"
        resumed.flag("source.photos", false).wrappedValue = false
        resumed.list("neverApps", ["1Password", "Banking apps"]).wrappedValue = ["1Password", "Banking apps"]
        resumed.number("tone.formality", 6).wrappedValue = 6
        XCTAssertNil(resumed.wizard.answers.options)
    }

    func testShortcutLabelsSplitIntoKeysAndBandsFollowTheMac() {
        XCTAssertEqual(SetupText.keys("⌥Space"), ["⌥", "Space"])
        XCTAssertEqual(SetupText.keys("⌥⌘J"), ["⌥", "⌘", "J"])
        XCTAssertEqual(SetupText.keys("----"), ["----"])
        XCTAssertEqual(SetupText.parameters(.forMemory(24 << 30)), "9")
        var wizard = SetupWizard(mac: Self.sampleMac)
        XCTAssertEqual(SetupText.band(wizard), .standard)
        wizard.storageGB = 60
        XCTAssertEqual(SetupText.band(wizard), .standard, "Pro needs 32 GB of memory too")
        wizard.mac.memoryBytes = 36 << 30
        XCTAssertEqual(SetupText.band(wizard), .pro)
        wizard.mac.memoryBytes = 16 << 30
        XCTAssertEqual(SetupText.band(wizard), .lite)
        XCTAssertEqual(SetupText.time(-15), SetupText.time(23 * 60 + 45), "times wrap round midnight")
    }

    func testBriefTimeReadsInTheMacsFormat() {
        let shown = SetupText.time(6 * 60 + 30)
        XCTAssertTrue(shown.contains("6") && shown.contains("30"), shown)
        XCTAssertEqual(SetupText.model(.forMemory(24 << 30)), "Qwen3.5-9B")
        XCTAssertEqual(SetupText.model(.forMemory(16 << 30)), "Qwen3.5-4B")
    }
}
