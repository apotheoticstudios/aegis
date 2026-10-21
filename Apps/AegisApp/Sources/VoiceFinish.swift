import AVFoundation
import Foundation

/// Aegis's voice finish (#204, DESIGN.md › Voice): each bundled voice clip plays through a small effects chain on this
/// Mac, so it sounds subtly like an AI rather than a plain recording: its pace (pitch kept), a touch of
/// high-frequency air, a low cut, a small room and gentle compression. Nothing is saved: each clip is read from a
/// private temporary file that is deleted at once.
@MainActor
final class VoiceFinish {
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private let pace = AVAudioUnitTimePitch()
    private let tone = AVAudioUnitEQ(numberOfBands: 2)
    private let room = AVAudioUnitReverb()
    private let dynamics = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
    ))
    private var format: AVAudioFormat?
    private var completion: PlaybackCompletion?

    init(rate: Float, engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        pace.rate = rate
        let air = tone.bands[0]
        air.filterType = .highShelf
        air.frequency = 7000
        air.gain = 2.5
        air.bypass = false
        let lowCut = tone.bands[1]
        lowCut.filterType = .highPass
        lowCut.frequency = 90
        lowCut.bypass = false
        room.loadFactoryPreset(.smallRoom)
        room.wetDryMix = 8
        for node in [player, pace, tone, room, dynamics] as [AVAudioNode] {
            engine.attach(node)
        }
    }

    var isPlaying: Bool {
        player.isPlaying
    }

    /// Plays one WAV clip to the end. False when it can't be played, or when `stop` cut it short.
    func play(_ wav: Data) async -> Bool {
        guard let buffer = Self.playbackBuffer(from: wav) else {
            DiagnosticLog.shared.record(.playbackFailed)
            return false
        }
        if completion != nil {
            stop()
        }
        if format != buffer.format {
            connect(buffer.format)
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                DiagnosticLog.shared.record(.playbackFailed, number: (error as NSError).code)
                return false
            }
        }
        let clip = clips + 1
        clips = clip
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = PlaybackCompletion(continuation)
            completion = done
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: Self.done(done))
            player.play()
        }
        // A newer clip or `stop` since this one started means it was cut short.
        guard clips == clip else { return false }
        completion = nil
        return true
    }

    /// Counts clips, so a clip cut short by `stop` can tell.
    private var clips = 0

    /// Cuts the current clip and releases its waiter even if the audio device drops its completion.
    func stop() {
        clips += 1
        let pending = completion
        completion = nil
        player.stop()
        engine.pause()
        pending?.resume()
    }

    private func connect(_ clip: AVAudioFormat) {
        engine.stop()
        for node in [player, pace, tone, room, dynamics] as [AVAudioNode] {
            engine.disconnectNodeOutput(node)
        }
        engine.connect(player, to: pace, format: clip)
        engine.connect(pace, to: tone, format: clip)
        engine.connect(tone, to: room, format: clip)
        engine.connect(room, to: dynamics, format: clip)
        engine.connect(dynamics, to: engine.mainMixerNode, format: clip)
        format = clip
    }

    /// Built outside the main actor: the audio system calls it on its own thread.
    private nonisolated static func done(
        _ completion: PlaybackCompletion
    ) -> AVAudioPlayerNodeCompletionHandler {
        { _ in completion.resume() }
    }

    static func playbackBuffer(from wav: Data) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-voice-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? wav.write(to: url, options: .atomic)) != nil,
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil
        else { return nil }
        // Apple's reverb rejects the model's 24 kHz mono format. Passing that format to
        // AVAudioEngine.connect raises an Objective-C exception instead of a catchable Swift error.
        // Convert before constructing the effects graph; all effects use 48 kHz stereo Float32.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2),
              let converter = AVAudioConverter(from: buffer.format, to: format),
              let output = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * 48000 / buffer.format.sampleRate)) + 32
              )
        else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            guard !supplied else { state.pointee = .endOfStream; return nil }
            supplied = true
            state.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

/// The render thread and Stop can both finish a clip; resume its task exactly once.
private final class PlaybackCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume()
    }
}
