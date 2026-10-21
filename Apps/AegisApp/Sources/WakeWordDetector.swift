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
        queue.async { [self] in detector?.reset() }
        lock.unlock()
    }

    func stop() {
        lock.withLock {
            enabled = false
            revision += 1
            queue.async { [self] in detector = nil; found = nil }
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        guard let mono = SpeechAudio.voiceChannel(buffer), let channel = mono.floatChannelData?[0] else { return }
        let rate = Int(buffer.format.sampleRate)
        guard (8000 ... 192_000).contains(rate) else { return }
        lock.lock()
        // Bound work to about half a second, never accumulate a recording behind a slow worker.
        guard enabled, pending < 24 else { lock.unlock(); return }
        let ticket = revision
        pending += 1
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(mono.frameLength)))
        queue.async { [self] in
            defer { lock.withLock { pending -= 1 } }
            guard lock.withLock({ enabled && revision == ticket }) else { return }
            guard detector?.accept(samples, sampleRate: rate) == true else { return }
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
}

/// Physically separates idle keyword audio from post-wake transcription audio.
final class WakeAudioRouter: @unchecked Sendable {
    enum Mode { case wake, question, interruption, paused }
    let audio = AudioRelay()
    let keyword = WakeWordDetector()
    private let lock = NSLock()
    private var current: Mode = .paused
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
