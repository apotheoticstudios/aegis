import AVFoundation
import Observation
import OSLog
import SharedIPC
import Speech

/// Talking to Aegis while the panel is open (#178): on-device speech recognition and synthesis.
/// Audio never leaves the Mac (recognition is on-device only) and nothing is recorded or kept. The
/// microphone is on only after the owner clicks the mic, and listening and speaking stop when the panel
/// closes (silent rule).
@MainActor
@Observable
final class Voice {
    enum State: Equatable {
        case idle
        /// Listening, with the words heard so far.
        case listening(String)
        /// Why voice can't be used right now, in plain words.
        case unavailable(String)
    }

    private(set) var state: State = .idle
    /// True while an answer is being read aloud (the reactor pulses).
    private(set) var speaking = false
    /// Used only in memory to suppress residual speaker echo during an active reply.
    private(set) var spokenText = ""

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var heard = ""
    private var pause: Task<Void, Never>?
    private var finished: ((String) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    /// The live session while listening (#213; a `LiveTranscriber` on macOS 26 and later).
    @ObservationIgnored private var live: AnyObject?
    private let localSpeech = VoiceXPCClient()
    private var voiceSession: Task<Void, Never>?
    /// Pace, air, a small room and gentle compression for the built-in voice clips (#204).
    @ObservationIgnored private let finish = VoiceFinish(rate: Voice.speakingRate)
    private var speech: Task<Void, Never>?

    var playingAudio: Bool {
        finish.isPlaying || synthesizer.isSpeaking
    }

    /// Slightly quicker than the voice's natural pace (owner's request); the pitch stays the same.
    static let speakingRate: Float = 1.12

    /// A pause this long ends the question.
    private static let pauseSeconds: Double = 1.6
    /// The longest a question may run.
    private static let maxSeconds: Double = 20

    var isListening: Bool {
        if case .listening = state {
            return true
        }
        return false
    }

    func inputFailed() {
        state = .unavailable("Aegis couldn't transcribe that. Please try again or type your question.")
    }

    /// Starts listening; `finished` gets the words once the owner pauses, or when `stop` is called.
    func listen(finished: @escaping (String) -> Void) async {
        stopSpeaking()
        guard !isListening else { return }
        guard await Self.speechAllowed(), await AVCaptureDevice.requestAccess(for: .audio) else {
            DiagnosticLog.shared.record(.permissionDenied)
            state = .unavailable("Allow Aegis to use Speech Recognition and the microphone in System Settings › Privacy & Security.")
            return
        }
        #if compiler(>=6.2)
            if #available(macOS 26, *), await listenLive(finished: finished) {
                return
            }
        #endif
        guard let recognizer = Self.onDeviceRecognizer() else {
            DiagnosticLog.shared.record(.legacyUnavailable)
            state = .unavailable("On-device speech recognition isn't available on this Mac, so Aegis won't listen.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Never Apple's servers: the words stay on this Mac.
        request.requiresOnDeviceRecognition = true
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tap(request))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            DiagnosticLog.shared.record(.microphoneFailed, number: (error as NSError).code)
            input.removeTap(onBus: 0)
            state = .unavailable("Aegis couldn't use the microphone.")
            return
        }
        self.request = request
        self.finished = finished
        heard = ""
        state = .listening("")
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results { [weak self] text, final in
            self?.heard(text, final: final)
        })
        restartPause(after: Self.maxSeconds)
    }

    #if compiler(>=6.2)
        /// Apple's SpeechAnalyzer (#213): live words while the owner speaks, quicker than the older recogniser.
        /// False when it can't start here; the older recogniser takes over.
        @available(macOS 26, *)
        private func listenLive(finished: @escaping (String) -> Void) async -> Bool {
            let session = LiveTranscriber()
            guard await session.start(heard: { [weak self] words, final in
                self?.heard(words, final: final)
            }) else { return false }
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.feed(session))
            engine.prepare()
            do {
                try engine.start()
            } catch {
                DiagnosticLog.shared.record(.microphoneFailed, number: (error as NSError).code)
                input.removeTap(onBus: 0)
                await session.cancel()
                state = .unavailable("Aegis couldn't use the microphone.")
                return true
            }
            live = session
            self.finished = finished
            heard = ""
            state = .listening("")
            restartPause(after: Self.maxSeconds)
            return true
        }

        @available(macOS 26, *)
        private nonisolated static func feed(_ session: LiveTranscriber) -> AVAudioNodeTapBlock {
            { buffer, _ in session.feed(buffer) }
        }
    #endif

    /// Stops listening and hands over what was heard (nothing when empty).
    func stop() {
        guard isListening else { return }
        let words = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = finished
        tearDown()
        state = .idle
        if !words.isEmpty {
            done?(words)
        }
    }

    /// The panel closed: no listening, no speaking.
    func silence() {
        if isListening {
            tearDown()
        }
        state = .idle
        stopSpeaking()
        voiceSession?.cancel()
        let previous = voiceSession
        voiceSession = Task { [localSpeech] in
            await localSpeech.stop()
            await previous?.value
        }
    }

    /// Reads an answer with the bundled voice, sentence by sentence; uses the system voice if unavailable.
    func speak(_ text: String) {
        stopSpeaking()
        speaking = true
        spokenText = text
        let parts = Self.passages(text)
        speech = Task { [weak self] in
            guard let self else { return }
            let spoken = await speakWithLocalVoice(parts)
            Logger(subsystem: "dev.aegis.app", category: "voice")
                .notice("speak: \(parts.count) passages, \(spoken) by local synthesis, cancelled \(Task.isCancelled)")
            guard !Task.isCancelled else { return }
            if spoken < parts.count {
                speakWithSystem(parts[spoken...].joined(separator: " "))
            } else {
                speaking = false
                spokenText = ""
            }
        }
    }

    // MARK: Speaking while thinking (#263)

    /// Sentences of a reply still being written, played in order as they arrive.
    @ObservationIgnored private var streamQueue: AsyncStream<String>.Continuation?

    func stopSpeaking() {
        streamQueue?.finish()
        streamQueue = nil
        speech?.cancel()
        speech = nil
        finish.stop()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        speaking = false
        spokenText = ""
    }

    /// Plays passages from the built-in voice, fetching the next while one plays. Returns how many were spoken.
    private func speakWithLocalVoice(_ parts: [String]) async -> Int {
        guard !parts.isEmpty else { return 0 }
        guard var next = await localSpeech.audio(for: parts[0]) else {
            if !Task.isCancelled {
                DiagnosticLog.shared.record(.synthesisFailed)
            }
            return 0
        }
        for index in parts.indices {
            // Synthesis can finish after Stop. Never start that delayed audio or a system fallback.
            guard !Task.isCancelled else { return parts.count }
            let current = next
            let upcoming: Task<Data?, Never>? = index + 1 < parts.count
                ? Task { [localSpeech] in await localSpeech.audio(for: parts[index + 1]) } : nil
            let played = await finish.play(current)
            guard !Task.isCancelled else {
                upcoming?.cancel()
                return parts.count
            }
            guard played else {
                DiagnosticLog.shared.record(.playbackFailed)
                upcoming?.cancel()
                return index // the system voice says the rest
            }
            guard let upcoming else { return parts.count }
            guard let fetched = await upcoming.value else {
                if !Task.isCancelled {
                    DiagnosticLog.shared.record(.synthesisFailed)
                }
                return index + 1
            }
            next = fetched
        }
        return parts.count
    }

    private func speakWithSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Self.speakingRate
        synthesizer.speak(utterance)
        speaking = true
        speech = Task { [weak self] in
            // Watch only while speaking; a quarter-second check is plenty for the reactor.
            while let self, speaking, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if !synthesizer.isSpeaking {
                    speaking = false
                    spokenText = ""
                }
            }
        }
    }

    /// Sentences grouped into passages of about 40 to 300 characters: short enough to start fast, long enough to
    /// keep the voice's flow.
    static func passages(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        var result: [String] = []
        for sentence in sentences {
            if let last = result.last, last.count < 40 || last.count + sentence.count < 120, last.count + sentence.count <= 300 {
                result[result.count - 1] = last + " " + sentence
            } else {
                result.append(sentence)
            }
        }
        return result
    }

    /// The panel opened: prepare the bundled voice in the background.
    func prepare(enabled: Bool) {
        guard enabled else { return }
        let previous = voiceSession
        voiceSession = Task { [localSpeech] in
            await previous?.value
            guard !Task.isCancelled else { return }
            _ = await localSpeech.prepare()
        }
    }

    func dismissNotice() {
        if case .unavailable = state {
            state = .idle
        }
    }

    private func heard(_ text: String, final: Bool) {
        guard isListening else { return }
        heard = text
        state = .listening(text)
        if final {
            stop()
        } else {
            restartPause(after: Self.pauseSeconds)
        }
    }

    private func restartPause(after seconds: Double) {
        pause?.cancel()
        pause = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func tearDown() {
        pause?.cancel()
        pause = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        #if compiler(>=6.2)
            if #available(macOS 26, *), let session = live as? LiveTranscriber {
                Task { await session.cancel() }
            }
        #endif
        live = nil
        finished = nil
    }

    /// The first recognizer for the owner's English that runs on this Mac.
    private static func onDeviceRecognizer() -> SFSpeechRecognizer? {
        for id in [Locale.current.identifier, "en-GB", "en-US"] {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)), recognizer.isAvailable,
               recognizer.supportsOnDeviceRecognition
            {
                return recognizer
            }
        }
        return nil
    }

    /// British English first (it's Aegis), best quality first, then any English voice.
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let rank: (AVSpeechSynthesisVoice) -> (Int, Int) = { voice in
            (voice.language == "en-GB" ? 0 : 1, -voice.quality.rawValue)
        }
        return english.min { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    // The audio tap and recognition results arrive off the main thread: these closures are made outside the
    // main actor so Swift doesn't treat them as main-actor code, then hop back to it.

    private nonisolated static func tap(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in request.append(buffer) }
    }

    private nonisolated static func results(
        _ deliver: @escaping @MainActor (String, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            if let error {
                DiagnosticLog.shared.record(.speechResultFailed, number: (error as NSError).code)
            }
            let text = result?.bestTranscription.formattedString ?? ""
            let final = result?.isFinal ?? (error != nil)
            Task { @MainActor in deliver(text, final) }
        }
    }

    private nonisolated static func speechAllowed() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

/// Speaking while thinking (#263).
extension Voice {
    /// Starts speaking a reply that's still being written; `continueStreaming` adds to it.
    func beginStreaming() {
        stopSpeaking()
        speaking = true
        let (parts, queue) = AsyncStream<String>.makeStream()
        streamQueue = queue
        speech = Task { [weak self] in
            await self?.playStream(parts)
        }
    }

    /// More of the reply: each passage is synthesised as soon as it arrives and played after the ones before it.
    func continueStreaming(_ text: String) {
        guard let streamQueue, !text.isEmpty else { return }
        spokenText += (spokenText.isEmpty ? "" : " ") + text
        for part in Self.passages(text) {
            streamQueue.yield(part)
        }
    }

    /// The reply is complete: speaking ends after what's queued.
    func endStreaming() {
        streamQueue?.finish()
        streamQueue = nil
    }

    private func playStream(_ parts: AsyncStream<String>) async {
        let (ready, sink) = AsyncStream<(String, Task<Data?, Never>)>.makeStream()
        let feeder = Task { [localSpeech] in
            for await part in parts {
                sink.yield((part, Task { await localSpeech.audio(for: part) }))
            }
            sink.finish()
        }
        defer { feeder.cancel() }
        var leftover: [String] = []
        for await (part, audio) in ready {
            guard !Task.isCancelled else {
                audio.cancel()
                return
            }
            // Once the bundled voice fails, the system voice says the rest at the end.
            guard leftover.isEmpty else {
                audio.cancel()
                leftover.append(part)
                continue
            }
            guard let data = await audio.value, !Task.isCancelled else {
                if Task.isCancelled {
                    return
                }
                DiagnosticLog.shared.record(.synthesisFailed)
                leftover.append(part)
                continue
            }
            guard await finish.play(data) else {
                if Task.isCancelled {
                    return
                }
                DiagnosticLog.shared.record(.playbackFailed)
                leftover.append(part)
                continue
            }
        }
        guard !Task.isCancelled else { return }
        if leftover.isEmpty {
            speaking = false
            spokenText = ""
        } else {
            speakWithSystem(leftover.joined(separator: " "))
        }
    }
}
