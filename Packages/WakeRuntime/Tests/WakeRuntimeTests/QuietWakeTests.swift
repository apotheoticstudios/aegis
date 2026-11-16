import Foundation
@testable import WakeRuntime
import XCTest

/// #207: "Hey …" at a normal speaking volume must wake, while silence and room noise must not.
/// Speech comes from the Mac's own synthetic voices at test time; no recordings are used or kept.
final class QuietWakeTests: XCTestCase {
    func testQuietSyntheticSpeechWakesWhileSilenceAndNoiseDoNot() throws {
        guard let directory = ProcessInfo.processInfo.environment["AEGIS_TEST_WAKE_MODEL_DIR"] else {
            throw XCTSkip("Provide the packaged public keyword model to check quiet wake phrases.")
        }
        let detector = try XCTUnwrap(KeywordDetector(directory: URL(fileURLWithPath: directory), additionalName: "Jarvis"))
        var seed: UInt64 = 41
        // About -80 dBFS of hiss: a quiet room at a laptop microphone.
        func room(_ count: Int, level: Float = 0.0003) -> [Float] {
            (0 ..< count).map { _ in
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                return (Float(seed >> 40) / Float(1 << 24) - 0.5) * level
            }
        }
        func wakes(_ samples: [Float]) -> Bool {
            detector.reset()
            return stride(from: 0, to: samples.count, by: 1024).contains {
                detector.accept(Array(samples[$0 ..< min($0 + 1024, samples.count)]), sampleRate: 16000)
            }
        }
        XCTAssertFalse(wakes([Float](repeating: 0, count: 16000 * 10)), "Silence must never wake.")
        XCTAssertFalse(wakes(room(16000 * 30)), "A quiet room must never wake.")
        XCTAssertFalse(wakes(room(16000 * 30, level: 0.06)), "Loud steady noise (about -35 dBFS) must never wake.")
        // The clip scaled to a peak level, with a second of the room either side.
        func spoken(_ clip: [Float], peak: Float) -> [Float] {
            let scale = peak / (clip.map(abs).max() ?? 1)
            var samples = [Float](repeating: 0, count: 16000) + clip.map { $0 * scale } + [Float](repeating: 0, count: 16000)
            for (index, noise) in room(samples.count).enumerated() {
                samples[index] += noise
            }
            return samples
        }
        // Peaks near -46 dBFS: a soft voice at a laptop microphone. Without the boost, Flo, Shelley and Grandpa
        // are missed here. Loud copies (-6 dBFS) must still wake, so the boost can't be too strong.
        for voice in Self.voices {
            let clip = try XCTUnwrap(Self.speech("Hey Jarvis", voice: voice), "The Mac's \(voice) voice is missing.")
            XCTAssertTrue(wakes(spoken(clip, peak: 0.005)), "A soft \"Hey Jarvis\" by \(voice) must wake.")
            XCTAssertTrue(wakes(spoken(clip, peak: 0.5)), "A loud \"Hey Jarvis\" by \(voice) must wake.")
        }
        for phrase in ["I told Jarvis about it", "Hey Travis", "Hey there. The jar is on the shelf."] {
            let clip = try XCTUnwrap(Self.speech(phrase, voice: "Samantha"))
            for peak: Float in [0.005, 0.5] {
                XCTAssertFalse(wakes(spoken(clip, peak: peak)), "\"\(phrase)\" at peak \(peak) must not wake.")
            }
        }
    }

    static let voices = ["Samantha", "Karen", "Daniel", "Moira", "Tessa", "Flo", "Eddy", "Shelley", "Grandpa"]

    /// Synthesises speech with the Mac's own voices into a temporary file, read back as 16 kHz mono floats.
    static func speech(_ text: String, voice: String) -> [Float]? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wake-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "--file-format=WAVE", "--data-format=LEF32@16000", "-o", url.path, text]
        guard (try? say.run()) != nil else { return nil }
        say.waitUntilExit()
        guard say.terminationStatus == 0, let data = try? Data(contentsOf: url) else { return nil }
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset ..< offset + 4], as: UTF8.self)
            let size = data[offset + 4 ..< offset + 8].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            if id == "data" {
                return data[offset + 8 ..< min(data.count, offset + 8 + size)].withUnsafeBytes { raw in
                    (0 ..< raw.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
                }
            }
            offset += 8 + size + size % 2
        }
        return nil
    }
}
