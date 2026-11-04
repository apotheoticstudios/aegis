import AVFoundation
import Foundation
import WakeRuntime

/// Only configured wake keywords are decoded while idle. This worker never returns arbitrary speech text.
final class WakeWordDetector: @unchecked Sendable {
    // Wake latency is felt directly, so detection isn't left behind background work (#303).
    private let queue = DispatchQueue(label: "dev.aegis.keyword", qos: .userInitiated)
    private let lock = NSLock()
    private var enabled = false
    private var revision = 0
    private var pending = 0
    // Accessed only by queue; the lock protects routing, not inference.
    private var detector: KeywordDetector?
    private var silence: WakeSilenceGate?
    private var found: (@MainActor @Sendable () -> Void)?

    func prepare(directory: URL, name: String? = nil, found: @escaping @MainActor @Sendable () -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                detector = KeywordDetector(directory: directory, additionalName: name)
                self.found = found
                continuation.resume(returning: detector != nil)
            }
        }
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        guard enabled != value else { lock.unlock(); return }
        enabled = value
        revision += 1
        queue.async { [self] in
            detector?.reset()
            silence = nil
        }
        lock.unlock()
    }

    func stop() {
        lock.withLock {
            enabled = false
            revision += 1
            queue.async { [self] in
                detector = nil
                silence = nil
                found = nil
            }
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        guard let mono = SpeechAudio.voiceChannel(buffer), let channel = mono.floatChannelData?[0] else { return }
        let rate = Int(buffer.format.sampleRate)
        guard (8000 ... 192_000).contains(rate), (1 ... rate).contains(Int(mono.frameLength)) else { return }
        lock.lock()
        // Bound work to about half a second, never accumulate a recording behind a slow worker.
        guard enabled, pending < 24 else { lock.unlock(); return }
        let ticket = revision
        pending += 1
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(mono.frameLength)))
        queue.async { [self] in
            defer { lock.withLock { pending -= 1 } }
            guard lock.withLock({ enabled && revision == ticket }) else { return }
            guard accept(samples, rate: rate) else { return }
            let deliver = lock.withLock {
                guard enabled, revision == ticket else { return false }
                enabled = false
                return true
            }
            guard deliver, let found else { return }
            Task { @MainActor [weak self] in
                guard let self, lock.withLock({ revision == ticket }) else { return }
                found()
            }
        }
        lock.unlock()
    }

    private func accept(_ samples: [Float], rate: Int) -> Bool {
        guard let detector else { return false }
        if silence?.sampleRate != rate {
            if silence != nil {
                detector.reset()
            }
            silence = WakeSilenceGate(sampleRate: rate)
        }
        guard let frame = silence?.feed(samples) else { return false }
        if let leadIn = frame.leadIn {
            // The skipped gap breaks acoustic continuity. Replay only the bounded tail before resuming.
            detector.reset()
            if detector.accept(leadIn, sampleRate: rate) {
                return true
            }
        }
        return detector.accept(samples, sampleRate: rate)
    }
}

/// Skip prolonged near-silence without applying a speech gate to post-wake questions.
struct WakeSilenceGate {
    struct Frame {
        /// Present on the first live buffer after a skipped gap.
        let leadIn: [Float]?
    }

    let sampleRate: Int
    private var quietSamples = 0
    private var recent: [Float] = []

    mutating func feed(_ samples: [Float]) -> Frame? {
        // A low peak threshold (about -66 dBFS) keeps even quiet speech in the detector.
        if samples.contains(where: { abs($0) >= 0.0005 }) {
            quietSamples = 0
            let leadIn = recent.isEmpty ? nil : recent
            recent = []
            return Frame(leadIn: leadIn)
        }
        let tail = sampleRate * 3 / 4
        if quietSamples < tail {
            quietSamples += samples.count
            return Frame(leadIn: nil)
        }
        let limit = sampleRate / 4
        recent.append(contentsOf: samples.suffix(limit))
        if recent.count > limit {
            recent.removeFirst(recent.count - limit)
        }
        return nil
    }
}

/// Physically separates idle keyword audio from post-wake transcription audio.
final class WakeAudioRouter: @unchecked Sendable {
    enum Mode { case wake, question, interruption, paused }
    let audio = AudioRelay()
    let keyword = WakeWordDetector()
    private let lock = NSLock()
    private var current: Mode = .paused
    private var wakeMeterFrames = 0
    private let wakeAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// The optional sink lets synthetic tests verify the routing boundary without loading a model.
    init(wakeAudio: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) {
        self.wakeAudio = wakeAudio
    }

    var mode: Mode {
        lock.withLock { current }
    }

    func set(_ mode: Mode) {
        lock.withLock {
            guard current != mode else { return }
            let recording: Set<Mode> = [.question, .interruption]
            let continuing = recording.contains(current) && recording.contains(mode)
            current = mode
            wakeMeterFrames = 0
            if !continuing {
                audio.end()
                audio.discardRecent()
            }
            keyword.setEnabled(mode == .wake)
        }
    }

    /// Called from the audio tap. Returns whether this frame may update the noise meter.
    func receive(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.withLock {
            switch current {
            case .wake:
                if let wakeAudio {
                    wakeAudio(buffer)
                } else {
                    keyword.receive(buffer)
                }
                // Keep the room calibration used for quiet questions, at the gate's own coarse cadence.
                // Only question and interruption modes need levels from every audio buffer.
                let interval = max(1, Int(buffer.format.sampleRate) / 8)
                wakeMeterFrames += Int(buffer.frameLength)
                guard wakeMeterFrames >= interval else { return false }
                wakeMeterFrames %= interval
                return true
            case .question, .interruption:
                audio.receive(buffer)
                return true
            case .paused:
                return false
            }
        }
    }
}
