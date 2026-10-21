import Foundation
@testable import WakeRuntime
import XCTest

final class KeywordDetectorTests: XCTestCase {
    func testMissingAssetsFailClosed() {
        XCTAssertNil(KeywordDetector(directory: URL(fileURLWithPath: "/synthetic-missing-wake-assets")))
    }

    func testCustomNamesUsePinnedUnigramTokens() throws {
        guard let directory = ProcessInfo.processInfo.environment["AEGIS_TEST_WAKE_MODEL_DIR"] else {
            throw XCTSkip("Provide the packaged public keyword model to verify custom-name encoding.")
        }
        let url = URL(fileURLWithPath: directory)
        let data = try Data(contentsOf: url.appendingPathComponent("token-scores.json"))
        let tokens = try KeywordTokens(scores: JSONDecoder().decode([String: Float].self, from: data))
        for (name, expected) in [
            ("Aegis", "▁HE Y ▁A E G IS"), ("Atlas", "▁HE Y ▁AT LA S"),
            ("Aurora", "▁HE Y ▁A UR OR A"), ("Friday", "▁HE Y ▁F RI DAY"), ("Evie", "▁HE Y ▁E VI E"),
        ] {
            XCTAssertEqual(tokens.encode("HEY " + name), expected)
        }
        let configured = try XCTUnwrap(KeywordTokens.keywords(directory: url, name: "Atlas"))
        XCTAssertTrue(configured.contains("@HEY_AEGIS"))
        XCTAssertTrue(configured.contains("▁HE Y ▁AT LA S @CUSTOM_NAME"))
        XCTAssertFalse(try XCTUnwrap(KeywordTokens.keywords(directory: url, name: "bad\nname")).contains("@CUSTOM_NAME"))
    }

    func testSustainedSyntheticRoomNoiseHasNoWakeAndRunsFasterThanRealtime() throws {
        guard let directory = ProcessInfo.processInfo.environment["AEGIS_TEST_WAKE_MODEL_DIR"] else {
            throw XCTSkip("Provide the packaged public keyword model for the inference benchmark.")
        }
        let detector = try XCTUnwrap(KeywordDetector(directory: URL(fileURLWithPath: directory), additionalName: "Friday"))
        var seed: UInt64 = 23
        let started = ContinuousClock.now
        for _ in 0 ..< 600 {
            let samples: [Float] = (0 ..< 1600).map { _ in
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                return (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.02
            }
            XCTAssertFalse(detector.accept(samples, sampleRate: 16000))
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(10), "Sixty seconds of audio must need well below one CPU core.")
    }
}
