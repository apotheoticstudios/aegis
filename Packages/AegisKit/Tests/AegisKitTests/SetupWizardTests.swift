@testable import AegisKit
import XCTest

final class SetupWizardTests: XCTestCase {
    private let gigabyte: UInt64 = 1_000_000_000

    private func mac(memory: UInt64 = 24, total: UInt64 = 512, free: UInt64 = 300, laptop: Bool = true) -> MacProfile {
        MacProfile(
            model: "MacBook Air", chip: "Apple M4", memoryBytes: memory * gigabyte, diskTotalBytes: total * gigabyte,
            diskFreeBytes: free * gigabyte, systemVersion: "26.1", appleIntelligence: true, isLaptop: laptop
        )
    }

    func testOfferedScreensFollowTheDesignWithoutUnbuiltOnes() {
        XCTAssertEqual(SetupStep.allCases.count, 15)
        XCTAssertEqual(SetupStep.offered, [
            .welcome, .mac, .storage, .schedule, .permissions, .sources, .privacy, .personality, .voice, .interface,
            .silence, .ready,
        ])
    }

    func testNextAndBackWalkTheScreensAndKeepAnswers() {
        var wizard = SetupWizard(mac: mac())
        XCTAssertEqual(wizard.current, .welcome)
        XCTAssertFalse(wizard.canGoBack)
        wizard.back()
        XCTAssertEqual(wizard.current, .welcome)

        wizard.next()
        wizard.next()
        XCTAssertEqual(wizard.current, .storage)
        XCTAssertEqual(wizard.position, 2)
        wizard.storageGB = 80
        wizard.next()
        wizard.back()
        wizard.back()
        XCTAssertEqual(wizard.current, .mac)
        XCTAssertEqual(wizard.storageGB, 80)
    }

    func testRecommendedForTheRestGoesToReadyAndNextFinishes() {
        var wizard = SetupWizard(mac: mac())
        wizard.next()
        wizard.useRecommendedForRest()
        XCTAssertEqual(wizard.current, .ready)
        XCTAssertFalse(wizard.finished)
        wizard.next()
        XCTAssertTrue(wizard.finished)

        wizard.restart()
        XCTAssertEqual(wizard.current, .welcome)
        XCTAssertFalse(wizard.finished)
    }

    func testStorageRangeAndRecommendation() {
        XCTAssertEqual(mac(total: 512).storageRange, 20 ... 384)
        XCTAssertEqual(mac(total: 20).storageRange, 20 ... 20)
        XCTAssertEqual(mac(memory: 24).recommendedStorageGB, 20)
        XCTAssertEqual(mac(memory: 36).recommendedStorageGB, 50)
        // Never more than half the free space, never under the minimum.
        XCTAssertEqual(mac(memory: 36, free: 60).recommendedStorageGB, 30)
        XCTAssertEqual(mac(memory: 36, free: 10).recommendedStorageGB, 20)
    }

    func testUnchangedAnswersFollowTheMacAndChangedOnesStay() {
        var wizard = SetupWizard(mac: mac(memory: 24, laptop: true))
        XCTAssertEqual(wizard.storageGB, 20)
        XCTAssertFalse(wizard.alwaysOn)
        XCTAssertEqual(wizard.briefMinutes, 7 * 60)
        XCTAssertFalse(wizard.wakeMacForBrief)

        wizard.mac.memoryBytes = 64 * gigabyte
        wizard.mac.isLaptop = false
        XCTAssertEqual(wizard.storageGB, 50)
        XCTAssertTrue(wizard.alwaysOn)

        wizard.storageGB = 100
        wizard.mac.memoryBytes = 16 * gigabyte
        XCTAssertEqual(wizard.storageGB, 100)
        // A smaller drive pulls a chosen amount back inside the range.
        wizard.mac.diskTotalBytes = 64 * gigabyte
        XCTAssertEqual(wizard.storageGB, 48)
    }

    func testWarnsWhenTheAssignmentIsMoreThanTheFreeSpace() {
        var wizard = SetupWizard(mac: mac(free: 40))
        wizard.storageGB = 40
        XCTAssertFalse(wizard.storageExceedsFreeSpace)
        wizard.storageGB = 41
        XCTAssertTrue(wizard.storageExceedsFreeSpace)
    }

    func testSavesAndResumes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = SetupFile(url: url)
        XCTAssertNil(try file.load())

        var wizard = SetupWizard(mac: mac())
        wizard.next()
        wizard.next()
        wizard.briefMinutes = 6 * 60 + 30
        try file.save(wizard)
        XCTAssertEqual(try file.load(), wizard)
    }

    func testASavedScreenNoLongerShownResumesAtTheNextOne() throws {
        var wizard = SetupWizard(mac: mac())
        wizard.steps = SetupStep.allCases
        for _ in 0 ..< 6 {
            wizard.next()
        }
        XCTAssertEqual(wizard.current, .home)

        var resumed = try JSONDecoder().decode(SetupWizard.self, from: JSONEncoder().encode(wizard))
        XCTAssertEqual(resumed.steps, SetupStep.offered)
        XCTAssertEqual(resumed.current, .privacy)
        resumed.back()
        XCTAssertEqual(resumed.current, .sources)
    }
}
