import AVFoundation
import Foundation
import Speech

/// An utterance-local recognizer. Test doubles supply invented results without a microphone.
protocol SpeechSession: AnyObject, Sendable {
    var isLegacy: Bool { get }
    @MainActor func start(heard: @escaping @MainActor @Sendable (String, Bool) -> Void) async -> Bool
    func feed(_ buffer: AVAudioPCMBuffer)
    func finish() async
    func cancel() async
}

/// Independent on-device fallback when SpeechAnalyzer cannot return a completed question.
final class LegacySpeechSession: SpeechSession, @unchecked Sendable {
    let isLegacy = true
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false
    private var ended = false
    private var formatReported = false

    @MainActor
    func start(heard: @escaping @MainActor @Sendable (String, Bool) -> Void) async -> Bool {
        let recognizer = [Locale.current.identifier, "en-AU", "en-GB", "en-US"]
            .compactMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }
            .first { $0.isAvailable && $0.supportsOnDeviceRecognition }
        guard let recognizer else {
            DiagnosticLog.shared.record(.legacyUnavailable)
            return false
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .search
        let ready = lock.withLock {
            guard !cancelled else { return false }
            self.request = request
            return true
        }
        guard ready else { return false }
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, lock.withLock({ !cancelled }) else { return }
            if let error {
                DiagnosticLog.shared.record(.speechResultFailed, number: (error as NSError).code)
            }
            let text = result?.bestTranscription.formattedString ?? ""
            let final = error != nil || result?.isFinal == true
            Task { @MainActor in heard(error == nil ? text : "", final) }
        }
        let stopped = lock.withLock {
            guard !cancelled else { return true }
            self.task = task
            return false
        }
        if stopped {
            task.cancel(); return false
        }
        return true
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let buffer = SpeechAudio.voiceChannel(buffer) else {
            DiagnosticLog.shared.record(.speechConversionFailed)
            return
        }
        let request = lock.withLock {
            guard !cancelled, !ended else { return nil as SFSpeechAudioBufferRecognitionRequest? }
            if !formatReported {
                formatReported = true
                DiagnosticLog.shared.record(
                    .speechInputFormat,
                    number: Int(buffer.format.sampleRate),
                    detail: Int(buffer.format.channelCount)
                )
            }
            return self.request
        }
        request?.append(buffer)
    }

    func finish() async {
        let request = lock.withLock {
            guard !ended else { return nil as SFSpeechAudioBufferRecognitionRequest? }
            ended = true
            return self.request
        }
        request?.endAudio()
    }

    func cancel() async {
        let (task, request) = lock.withLock {
            cancelled = true
            let old = (self.task, ended ? nil : self.request)
            ended = true
            self.task = nil
            self.request = nil
            return old
        }
        task?.cancel()
        request?.endAudio()
    }
}

/// Use the same voice channel as the keyword detector and level meter. Voice-processing inputs can
/// expose extra reference channels; an automatic multichannel downmix can discard the microphone.
enum SpeechAudio {
    static func voiceChannel(_ buffer: AVAudioPCMBuffer, alwaysCopy: Bool = false) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0,
              let input = buffer.floatChannelData?[0] else { return nil }
        if !alwaysCopy, buffer.format.channelCount == 1, buffer.stride == 1 {
            return buffer
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let output = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = buffer.frameLength
        for frame in 0 ..< Int(buffer.frameLength) {
            output[frame] = input[frame * buffer.stride]
        }
        return mono
    }
}
