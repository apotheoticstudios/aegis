import Darwin
import Foundation
@testable import VoiceRuntime
import XCTest

@MainActor
final class LocalSpeechTests: XCTestCase {
    func testMissingBundledModelsUseFallback() async {
        let voice = LocalSpeech(models: URL(fileURLWithPath: "/synthetic/missing-models"))
        let audio = await voice.audio(for: "A synthetic example.")
        XCTAssertNil(audio)
    }

    func testConcurrentPreparationSharesLoadAndCloseReleasesModel() async {
        let gate = Gate()
        let tracker = Tracker()
        let voice = LocalSpeech(makeModel: {
            await gate.wait()
            return tracker.makeModel()
        })
        let first = Task { await voice.prepare() }
        let second = Task { await voice.prepare() }
        while await !gate.waiting {
            await Task.yield()
        }
        await gate.open()
        let results = await (first.value, second.value)
        XCTAssertTrue(results.0 && results.1)
        XCTAssertEqual(tracker.loads, 1)
        let audio = await voice.audio(for: "Synthetic input.")
        XCTAssertEqual(audio, Data("synthetic audio".utf8))
        await voice.stop()
        for _ in 0 ..< 100 where tracker.alive {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(tracker.alive)
        let reopened = await voice.prepare()
        XCTAssertTrue(reopened)
        XCTAssertEqual(tracker.loads, 2)
        await voice.stop()
    }

    func testCloseDuringLoadDiscardsItAndReopenWaitsForDrain() async {
        let gate = Gate()
        let tracker = Tracker()
        let voice = LocalSpeech(makeModel: {
            await gate.wait()
            return tracker.makeModel()
        })
        let preparing = Task { await voice.prepare() }
        while await !gate.waiting {
            await Task.yield()
        }
        await voice.stop()
        let reopening = Task { await voice.prepare() }
        await gate.open()
        let old = await preparing.value
        let new = await reopening.value
        XCTAssertFalse(old)
        XCTAssertTrue(new)
        XCTAssertEqual(tracker.loads, 2)
        await voice.stop()
    }

    func testCancelledPredictionCannotPlayOrOverlapNewModel() async {
        let fixture = BlockingModel()
        let tracker = Tracker()
        let voice = LocalSpeech(makeModel: { tracker.recordLoad(); return fixture })
        let speaking = Task { await voice.audio(for: "Synthetic example.") }
        while !fixture.started {
            await Task.yield()
        }
        speaking.cancel()
        await voice.stop()
        let reopening = Task { await voice.prepare() }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(tracker.loads, 1)
        fixture.unblock()
        let cancelled = await speaking.value
        let reopened = await reopening.value
        XCTAssertNil(cancelled)
        XCTAssertTrue(reopened)
        XCTAssertEqual(tracker.loads, 2)
        await voice.stop()
    }

    func testFailureCanRetryAndOversizedInputIsRejectedBeforeLoading() async {
        let tracker = Tracker()
        let voice = LocalSpeech(makeModel: {
            tracker.recordLoad()
            if tracker.loads == 1 {
                throw CocoaError(.fileReadCorruptFile)
            }
            return FixtureModel()
        })
        let long = await voice.audio(for: String(repeating: "x", count: 1201))
        XCTAssertNil(long)
        XCTAssertEqual(tracker.loads, 0)
        let failed = await voice.prepare()
        let retried = await voice.prepare()
        XCTAssertFalse(failed)
        XCTAssertTrue(retried)
        await voice.stop()
    }

    func testWaveIsValidPCMAndClampsInvalidSamples() throws {
        let wave = try SpeechWave.encode([-2, 0, 2, .nan])
        XCTAssertEqual(String(data: wave.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wave[8 ..< 16], encoding: .ascii), "WAVEfmt ")
        XCTAssertEqual(Array(wave[24 ..< 28]), [0xC0, 0x5D, 0, 0]) // 24 kHz
        XCTAssertEqual(Array(wave[44...]), [1, 128, 0, 0, 255, 127, 0, 0])
        XCTAssertEqual(wave.count, 52)
        XCTAssertThrowsError(try SpeechWave.encode([]))
    }

    func testNativeSynthesisWithDownloadedPublicModelWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["AEGIS_VOICE_MODELS"] else {
            throw XCTSkip("Run with AEGIS_VOICE_MODELS pointing to the verified public build assets for a native smoke check.")
        }
        let voice = LocalSpeech(models: URL(fileURLWithPath: path))
        let baseline = residentBytes()
        for _ in 0 ..< 2 {
            let start = ContinuousClock.now
            let ready = await voice.prepare()
            XCTAssertTrue(ready)
            let loaded = ContinuousClock.now
            let audio = await voice.audio(for: "Good morning. Your synthetic test is ready.")
            let data = try XCTUnwrap(audio)
            XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
            XCTAssertGreaterThan(data.count, 24000)
            XCTAssertTrue(data.dropFirst(44).contains { $0 != 0 })
            print("Native voice: load \(start.duration(to: loaded)), synthesis \(loaded.duration(to: .now)), bytes \(data.count)")
            await voice.stop()
            try await Task.sleep(for: .milliseconds(500))
            print("Native voice: resident bytes after close \(residentBytes()), baseline \(baseline)")
        }
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }
}

private struct FixtureModel: SpeechModel {
    func audio(for _: String) throws -> Data {
        Data("synthetic audio".utf8)
    }
}

private final class TrackedModel: SpeechModel {
    func audio(for _: String) throws -> Data {
        Data("synthetic audio".utf8)
    }
}

private final class Tracker: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private weak var instance: TrackedModel?
    var loads: Int {
        lock.withLock { count }
    }

    var alive: Bool {
        lock.withLock { instance != nil }
    }

    func recordLoad() {
        lock.withLock { count += 1 }
    }

    func makeModel() -> TrackedModel {
        lock.withLock {
            count += 1
            let model = TrackedModel()
            instance = model
            return model
        }
    }
}

private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    var waiting: Bool {
        continuation != nil
    }

    func wait() async {
        if opened {
            return
        }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private final class BlockingModel: SpeechModel, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var running = false
    var started: Bool {
        lock.withLock { running }
    }

    func unblock() {
        semaphore.signal()
    }

    func audio(for _: String) throws -> Data {
        lock.withLock { running = true }
        semaphore.wait()
        return Data("cancelled synthetic audio".utf8)
    }
}
