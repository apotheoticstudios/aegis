import AegisKit
import AVFoundation
import Observation
import OSLog
import Speech

/// Opt-in hands-free voice: a dedicated keyword detector runs while idle. General speech recognition
/// starts only after "Hey Aegis" and its acknowledgement, and stops when the owner says "End Conversation".
/// Audio stays in memory on this Mac; idle sound never enters the question transcriber.
@MainActor
@Observable
final class WakeListener {
    static let enabledKey = "listenForHeyAegis"

    /// True while the microphone is open for the wake phrase.
    var listening = false
    /// Why hands-free voice can't run, in plain words.
    private(set) var problem: String?

    /// What the app does when the conversation calls for it.
    @ObservationIgnored var openPanel: () -> Void = {}
    @ObservationIgnored var ask: (String) -> Void = { _ in }
    /// A bare wake phrase gets a short spoken acknowledgement before the question is captured.
    @ObservationIgnored var acknowledge: () -> Void = {}
    /// Clears the visible voice conversation only on an explicit spoken ending.
    @ObservationIgnored var conversationEnded: () -> Void = {}
    /// Identifies the active utterance; cancelled recognition must not finish a newer utterance.
    @ObservationIgnored private(set) var segmentID = UUID()
    /// Whether Aegis is speaking now (its own voice must never count as the owner's).
    @ObservationIgnored var isSpeaking: () -> Bool = { false }
    @ObservationIgnored var isAnswering: () -> Bool = { false }
    @ObservationIgnored var isPlayingReply: () -> Bool = { false }
    @ObservationIgnored var isPanelOpen: () -> Bool = { true }
    @ObservationIgnored var playbackText: () -> String = { "" }
    @ObservationIgnored var interruptSpeech: () -> Void = {}
    /// The words heard so far of a spoken question, for CHAT's live line; empty when none is being spoken.
    @ObservationIgnored var hearing: (String) -> Void = { _ in }
    /// False on unsupported devices: never interpret raw speaker echo as an owner interruption.
    @ObservationIgnored var echoCancellationReady = false
    @ObservationIgnored private var segmentForInterruption = false
    @ObservationIgnored private var interruption = InterruptionIntent.Confirmation()

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private let router: WakeAudioRouter
    private var audio: AudioRelay {
        router.audio
    }

    @ObservationIgnored private var startup = UUID()
    @ObservationIgnored private var configuredName: String?
    @ObservationIgnored private var acknowledging = false
    @ObservationIgnored private var acknowledgingSince: TimeInterval?
    @ObservationIgnored private var gate = WakeActivityGate()
    @ObservationIgnored private var window = ConversationWindow()
    @ObservationIgnored private var capture: (any SpeechSession)?
    @ObservationIgnored private var captureStart: Task<Void, Never>?
    @ObservationIgnored private var retriedCapture = false
    @ObservationIgnored private var capturePreparing = false
    @ObservationIgnored private var preferLegacy = false
    @ObservationIgnored var captureFailed: () -> Void = {}
    @ObservationIgnored var makeSpeechSession: (Bool) -> any SpeechSession = { legacy in
        #if compiler(>=6.2)
            if #available(macOS 26, *), !legacy {
                return LiveTranscriber()
            }
        #endif
        return LegacySpeechSession()
    }

    /// True from speech start until its words are in: one utterance at a time.
    @ObservationIgnored private var segmentOpen = false
    @ObservationIgnored private var segmentEnded = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var wasSpeaking = false
    /// Bounds an individual recognition session without expiring the conversation.
    @ObservationIgnored private var segmentStartedAt: TimeInterval?
    @ObservationIgnored private let clock = ContinuousClock()
    /// Counts, levels and yes/no only, never the owner's words (#204).
    @ObservationIgnored private let log = Logger(subsystem: "dev.aegis.app", category: "wake")
    @ObservationIgnored private var loudest: Float = -120
    @ObservationIgnored private var quietest: Float = 0
    @ObservationIgnored private var lastReport: TimeInterval = 0
    @ObservationIgnored private let started = ContinuousClock.now

    private static let segmentLimit: TimeInterval = 23
    private static let thinkingLimit: TimeInterval = 90

    init(router: WakeAudioRouter = WakeAudioRouter()) {
        self.router = router
    }

    /// Opens the microphone for the wake phrase, when switched on and allowed.
    func start() async {
        guard enabled, !listening else { return }
        startup = UUID()
        let attempt = startup
        problem = nil
        let speech = await Self.speechAllowed()
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        log.notice("wake start: speech allowed \(speech), mic allowed \(mic)")
        guard speech, mic else {
            DiagnosticLog.shared.record(.permissionDenied)
            problem = "Allow Aegis to use Speech Recognition and the microphone in System Settings › Privacy & Security."
            return
        }
        guard enabled, startup == attempt else { return }
        guard let resources = Bundle.main.resourceURL else { return }
        configuredName = Self.customName
        let ready = await router.keyword
            .prepare(directory: resources.appendingPathComponent("WakeModels"), name: configuredName) { [weak self] in
                guard let self, listening else { return }
                wakeDetected()
            }
        guard startup == attempt else { return }
        guard enabled else { router.keyword.stop(); return }
        guard ready else {
            DiagnosticLog.shared.record(.wakeModelMissing)
            problem = "Aegis's wake-word model is missing. Reinstall the complete app to enable Hey Aegis."
            return
        }
        guard startMicrophone(echo: isPanelOpen()) else {
            DiagnosticLog.shared.record(.microphoneFailed)
            router.keyword.stop()
            problem = "Aegis couldn't use the microphone."
            return
        }
        listening = true
        router.set(.wake)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    /// Closes the microphone (switched off, or the mic button needs it).
    func stop() {
        startup = UUID()
        router.set(.paused)
        router.keyword.stop()
        echoCancellationReady = false
        acknowledging = false
        ticker?.cancel()
        ticker = nil
        cancelSegment()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        listening = false
        gate = WakeActivityGate()
        _ = window.cancel()
        segmentStartedAt = nil
        thinkingSince = nil
        wasSpeaking = false
    }

    func heard(level: Float, at _: TimeInterval) {
        guard listening else { return }
        let time = now
        loudest = max(loudest, level)
        quietest = min(quietest, level)
        if time - lastReport > 10 {
            let low = quietest, high = loudest
            log.notice("wake levels: quietest \(low, privacy: .public) dBFS, loudest \(high, privacy: .public) dBFS")
            loudest = -120
            quietest = 0
            lastReport = time
        }
        if (isSpeaking() && router.mode != .interruption) || isAnswering() {
            // Aegis's own voice: no segments, and the gate restarts after it so its tail doesn't count.
            if segmentOpen {
                cancelSegment()
            }
            audio.discardRecent()
            gate.resetSpeech()
            updateAudioRoute()
            return
        }
        switch gate.feed(
            level: level, at: time, capture: router.mode == .question || router.mode == .interruption,
            interruption: router.mode == .interruption
        ) {
        case .speechStarted:
            log.notice("wake: speech started")
            if case .followUp = window.state {
                perform(window.heard(at: time))
            }
            beginSegment()
        case .speechEnded:
            log.notice("wake: speech ended")
            endSegment()
        case nil:
            break
        }
    }

    /// One utterance, recognised on this Mac.
    func segment(_ text: String?, id: UUID? = nil) {
        guard id == nil || id == segmentID else { return }
        hearing("")
        interruption.reset()
        segmentID = UUID()
        captureStart?.cancel()
        captureStart = nil
        if let capture {
            Task { await capture.cancel() }
        }
        capture = nil
        capturePreparing = false
        audio.end()
        audio.discardRecent()
        segmentOpen = false
        segmentStartedAt = nil
        let words = text?.split(separator: " ").count ?? 0
        log.notice("wake: heard \(words) words, phrase matched \(text.flatMap { WakePhrase.match($0, also: Self.customName) } != nil)")
        guard !isSpeaking(), !isAnswering(), let text, !text.isEmpty else { return }
        // Transcripts cannot wake Aegis; idle input belongs exclusively to the keyword detector.
        guard window.state != .waitingForWake else { return }
        if isEndCommand(text) {
            endConversation()
        } else if let match = WakePhrase.match(text, also: Self.customName) {
            switch window.state {
            case .capturing, .followUp:
                if let question = match.question, isEndCommand(question) {
                    endConversation()
                } else {
                    beginWake(question: match.question)
                }
            default: break
            }
        } else if window.state == .capturing {
            perform(window.questionComplete(text))
        }
    }

    /// Called only by the keyword detector, which supplies no transcript.
    func wakeDetected() {
        guard window.state == .waitingForWake, !isSpeaking() else { return }
        cancelSegment()
        beginWake(question: nil)
    }

    private func beginWake(question: String?) {
        _ = window.cancel()
        preferLegacy = false
        DiagnosticLog.shared.record(.wakeAcknowledged)
        acknowledging = question == nil
        acknowledgingSince = question == nil ? now : nil
        updateAudioRoute()
        perform(window.wake())
        if let question {
            perform(window.questionComplete(question))
        } else {
            acknowledge()
            if isSpeaking() {
                wasSpeaking = true
                segmentStartedAt = nil
            } else {
                acknowledging = false
            }
            updateAudioRoute()
        }
    }

    private func perform(_ action: ConversationWindow.Action) {
        if action != .none {
            let kind = switch action {
            case .openPanel: "open panel"
            case .startCapture: "start capture"
            case .ask: "ask"
            case .stopListening: "stop listening"
            case .none: "none"
            }
            log.notice("wake action: \(kind, privacy: .public)")
        }
        switch action {
        case .openPanel:
            openPanel()
        case .startCapture:
            break
        case let .ask(question):
            segmentStartedAt = nil
            thinkingSince = now
            ask(question)
        case .stopListening:
            segmentStartedAt = nil
            thinkingSince = nil
            acknowledging = false
            cancelSegment()
        case .none:
            break
        }
        updateAudioRoute()
    }

    @ObservationIgnored private var thinkingSince: TimeInterval?

    /// Follows playback and recovers stalled recognition; silence never expires the conversation.
    func tick(at time: TimeInterval? = nil) {
        if listening, window.state == .waitingForWake, configuredName != Self.customName {
            stop()
            Task { [weak self] in await self?.start() }
            return
        }
        if !isPanelOpen(), window.state != .waitingForWake {
            perform(window.cancel())
        }
        let time = time ?? now
        if acknowledging, let since = acknowledgingSince, time - since > 30 {
            DiagnosticLog.shared.record(.acknowledgementTimedOut)
            interruptSpeech()
            acknowledging = false
            acknowledgingSince = nil
            wasSpeaking = false
            gate.resetSpeech()
            audio.discardRecent()
        }
        let speaking = isSpeaking()
        if speaking, !wasSpeaking {
            thinkingSince = nil
            perform(window.startedSpeaking())
        } else if !speaking, wasSpeaking {
            if segmentForInterruption {
                cancelSegment()
            }
            acknowledging = false
            acknowledgingSince = nil
            audio.discardRecent()
            gate.resetSpeech()
            perform(window.finishedSpeaking(at: time))
            // Enter capture immediately: this app keeps listening until the explicit ending command.
            perform(window.heard(at: time))
        }
        wasSpeaking = speaking
        if segmentOpen, let since = segmentStartedAt {
            if capturePreparing, time - since > 10, !retriedCapture {
                DiagnosticLog.shared.record(.speechSetupFailed)
                recoverCapture()
            } else if time - since > Self.segmentLimit {
                DiagnosticLog.shared.record(.captureTimedOut)
                problem = "Speech recognition timed out. Please try again."
                captureFailed()
                cancelSegment()
            }
        }
        if window.state == .thinking, !isAnswering(), let since = thinkingSince, time - since > Self.thinkingLimit {
            thinkingSince = nil
            _ = window.cancel()
            _ = window.wake()
        }
        updateAudioRoute()
    }
}

extension WakeListener {
    func beginSegment() {
        guard router.mode == .question || router.mode == .interruption, !segmentOpen else { return }
        segmentForInterruption = router.mode == .interruption
        interruption.reset()
        segmentID = UUID()
        segmentOpen = true
        segmentStartedAt = now
        segmentEnded = false
        retriedCapture = false
        audio.beginCapture()
        DiagnosticLog.shared.record(.captureStarted)
        problem = nil
        startCapture(legacy: preferLegacy)
    }

    private func startCapture(legacy: Bool) {
        captureStart?.cancel()
        if let capture {
            Task { await capture.cancel() }
        }
        segmentID = UUID()
        let id = segmentID
        let session = makeSpeechSession(legacy)
        capture = session
        retriedCapture = session.isLegacy
        capturePreparing = true
        let began = now
        captureStart = Task { [weak self] in
            let ready = await session.start { [weak self] words, final in
                self?.receivedTranscript(words, final: final, id: id)
            }
            guard let self, segmentID == id, !Task.isCancelled else { await session.cancel(); return }
            capturePreparing = false
            guard ready else { recoverCapture(); return }
            DiagnosticLog.shared.record(.speechReady, number: Int((now - began) * 1000), detail: session.isLegacy ? 1 : 0)
            audio.begin { session.feed($0) }
            if segmentEnded {
                audio.end(); await session.finish()
            }
        }
    }

    private func endSegment() {
        segmentEnded = true
        audio.end()
        DiagnosticLog.shared.record(.captureEnded)
        if let capture {
            Task { await capture.finish() }
        }
    }

    private func recoverCapture() {
        guard !segmentForInterruption else { segment(nil); return }
        if !retriedCapture, capture != nil {
            retriedCapture = true
            preferLegacy = true
            DiagnosticLog.shared.record(.legacyRetry)
            startCapture(legacy: true)
            return
        }
        problem = "Aegis couldn't transcribe that. Please try again or use the text box."
        captureFailed()
        segment(nil)
    }

    private func cancelSegment() {
        hearing("")
        interruption.reset()
        segmentID = UUID()
        captureStart?.cancel()
        captureStart = nil
        if let capture {
            Task { await capture.cancel() }
        }
        capture = nil
        capturePreparing = false
        audio.end()
        audio.discardRecent()
        segmentOpen = false
        segmentStartedAt = nil
        segmentEnded = false
        segmentForInterruption = false
        gate.resetSpeech()
    }
}

extension WakeListener {
    /// A ready answer releases capture immediately when no playback starts; it never waits for a timer.
    func answerFinished() {
        guard window.state == .thinking else { updateAudioRoute(); return }
        thinkingSince = nil
        if isSpeaking() {
            wasSpeaking = true
            perform(window.startedSpeaking())
        } else {
            _ = window.cancel()
            _ = window.wake()
            updateAudioRoute()
        }
    }
}

extension WakeListener {
    /// Partial results may take the turn during playback; the same recognizer keeps the utterance's opening.
    func receivedTranscript(_ text: String?, final: Bool, id: UUID, at time: TimeInterval? = nil) {
        guard id == segmentID else { return }
        guard isPanelOpen() else { cancelSegment(); perform(window.cancel()); return }
        if router.mode == .interruption {
            segmentForInterruption = true
        }
        if segmentForInterruption {
            guard echoCancellationReady, isPlayingReply(), isSpeaking(), !acknowledging, !isAnswering() else {
                interruption.reset()
                if final {
                    segment(nil, id: id)
                }
                return
            }
            guard let text, interruption.accepts(
                text, playback: playbackText(), addressed: WakePhrase.match(text, also: Self.customName) != nil, at: time ?? now
            )
            else {
                if text == nil {
                    interruption.reset()
                }
                if final {
                    segment(nil, id: id)
                }
                return
            }
            interruptSpeech()
            // Never promote the transcript if the playback owner couldn't stop it.
            guard !isSpeaking() else { return }
            segmentForInterruption = false
            acknowledging = false
            thinkingSince = nil
            wasSpeaking = false
            _ = window.cancel()
            _ = window.wake()
            updateAudioRoute()
        }
        if final, text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false, !segmentForInterruption, segmentOpen {
            DiagnosticLog.shared.record(.transcriptEmpty)
            // Both recognisers heard no words: background noise, not a failure to show the owner (#303).
            if retriedCapture {
                segment(nil, id: id)
            } else {
                recoverCapture()
            }
        } else if final {
            segment(text, id: id)
        } else if !segmentForInterruption, let text {
            hearing(text)
        }
    }
}

private extension WakeListener {
    /// Echo cancellation costs about a quarter of a core and is only needed while Aegis can speak: with the panel open.
    func startMicrophone(echo: Bool) -> Bool {
        let input = engine.inputNode
        if !echo {
            try? input.setVoiceProcessingEnabled(false)
        }
        echoCancellationReady = echo && configureEchoCancellation(input)
        for _ in 0 ..< 2 {
            let format = input.outputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 {
                DiagnosticLog.shared.record(.microphoneFormat, number: Int(format.sampleRate), detail: Int(format.channelCount))
                input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(router, levels: { [weak self] level, time in
                    Task { @MainActor in self?.heard(level: level, at: time) }
                }))
                engine.prepare()
                do {
                    try engine.start()
                    return true
                } catch {
                    DiagnosticLog.shared.record(.microphoneFailed, number: (error as NSError).code)
                    input.removeTap(onBus: 0)
                    engine.stop()
                }
            }
            guard echoCancellationReady else { return false }
            // Some devices accept the property but cannot start voice processing. Retry legacy wake capture.
            try? input.setVoiceProcessingEnabled(false)
            echoCancellationReady = false
        }
        return false
    }

    func configureEchoCancellation(_ input: AVAudioInputNode) -> Bool {
        do {
            try input.setVoiceProcessingEnabled(true)
            // Aegis's voice uses its own effects engine. Keep automatic ducking of other audio minimal.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            return input.isVoiceProcessingEnabled
        } catch {
            DiagnosticLog.shared.record(.echoUnavailable, number: (error as NSError).code)
            log.notice("wake: echo cancellation unavailable")
            return false
        }
    }

    func isEndCommand(_ text: String) -> Bool {
        text.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) == ["end", "conversation"]
    }

    func endConversation() {
        perform(window.cancel())
        conversationEnded()
    }

    private var now: TimeInterval {
        let elapsed = started.duration(to: clock.now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func updateAudioRoute() {
        if isPlayingReply(), isSpeaking(), !acknowledging, !isAnswering(), echoCancellationReady, isPanelOpen() {
            if router.mode != .interruption, segmentOpen {
                cancelSegment()
            }
            router.set(.interruption); return
        }
        if acknowledging || isSpeaking() || isAnswering() {
            // Pending interruption evidence belongs to this reply, not a replacement question/reply.
            if segmentForInterruption {
                cancelSegment()
            }
            router.set(.paused); return
        }
        switch window.state {
        case .waitingForWake: router.set(.wake)
        case .capturing, .followUp: router.set(.question)
        case .thinking, .speaking: router.set(.paused)
        }
    }

    // Audio and recognition callbacks arrive off the main thread: these closures are made outside the main
    // actor, then hop back to it.

    private nonisolated static func tap(
        _ router: WakeAudioRouter, levels: @escaping @Sendable (Float, TimeInterval) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if router.receive(buffer) {
                levels(level(buffer), Date().timeIntervalSinceReferenceDate)
            }
        }
    }

    /// The buffer's loudness in dBFS (RMS of the first channel).
    private nonisolated static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -120 }
        var sum: Float = 0
        for index in 0 ..< Int(buffer.frameLength) {
            let sample = samples[index * buffer.stride]
            sum += sample * sample
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -120
    }

    private nonisolated static func speechAllowed() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

/// Moves microphone audio to the transcriber from the audio thread: it keeps the last second and a half, so the start
/// of a post-wake question isn't lost while speech is detected and the transcriber starts, and passes audio on while a
/// segment is open.
final class AudioRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let delivery = NSLock()
    private var recent: [AVAudioPCMBuffer] = []
    private var captured: [AVAudioPCMBuffer]?
    private var capturedSeconds = 0.0
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var ending: (@Sendable () -> Void)?
    private static let keep = 1.5

    /// Called once when the open segment ends (the older recogniser's endAudio).
    var onEnd: (@Sendable () -> Void)? {
        get { lock.withLock { ending } }
        set { lock.withLock { ending = newValue } }
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        guard let copy = SpeechAudio.voiceChannel(buffer, alwaysCopy: true) else { return }
        delivery.lock()
        defer { delivery.unlock() }
        lock.lock()
        let sink = sink
        if captured != nil {
            captured?.append(copy)
            capturedSeconds += Double(copy.frameLength) / copy.format.sampleRate
            while capturedSeconds > 24, let first = captured?.first {
                capturedSeconds -= Double(first.frameLength) / first.format.sampleRate
                captured?.removeFirst()
            }
        } else if sink == nil {
            recent.append(copy)
            var seconds = recent.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
            while seconds > Self.keep, let first = recent.first {
                seconds -= Double(first.frameLength) / first.format.sampleRate
                recent.removeFirst()
            }
        }
        lock.unlock()
        sink?(copy)
    }

    /// Opens a segment: the recent audio first, then everything live.
    func begin(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        // Replay must precede live frames even when recognition setup finishes on another thread.
        delivery.lock()
        defer { delivery.unlock() }
        let lead = lock.withLock {
            let lead = captured ?? recent
            recent = []
            self.sink = sink
            return lead
        }
        for buffer in lead {
            sink(buffer)
        }
    }

    /// Retain this one utterance while a model starts or a failed recognizer retries. Never persisted.
    func beginCapture() {
        lock.withLock {
            captured = recent
            capturedSeconds = recent.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
            recent = []
        }
    }

    /// Discards Aegis's own speech so it cannot be replayed as the next question's lead-in.
    func discardRecent() {
        lock.withLock {
            recent.removeAll(keepingCapacity: true)
            captured = nil
            capturedSeconds = 0
        }
    }

    /// Closes the segment.
    func end() {
        let ending = lock.withLock {
            sink = nil
            let ending = self.ending
            self.ending = nil
            return ending
        }
        ending?()
    }
}

extension WakeListener {
    var inputMode: WakeAudioRouter.Mode {
        router.mode
    }

    /// The owner's one-word custom wake name; "Hey Aegis" remains available.
    static var customName: String? {
        UserDefaults.aegis.string(forKey: PanelModel.wakeNameKey)
    }
}

extension WakeListener {
    /// The panel opened or closed (#313): the microphone restarts with echo cancellation only while it's open, since
    /// Aegis never speaks with it closed.
    func panelChanged(open: Bool) {
        guard listening, open != engine.inputNode.isVoiceProcessingEnabled else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // A reused engine keeps a stale multi-channel input after voice processing turns off: start a fresh one.
        engine = AVAudioEngine()
        audio.discardRecent()
        guard startMicrophone(echo: open) else {
            DiagnosticLog.shared.record(.microphoneFailed)
            stop()
            problem = "Aegis couldn't use the microphone."
            return
        }
    }
}

extension WakeListener {
    var enabled: Bool {
        UserDefaults.aegis.bool(forKey: Self.enabledKey)
    }

    /// Switches hands-free voice on or off (the owner's choice, remembered).
    func set(enabled: Bool) async {
        UserDefaults.aegis.set(enabled, forKey: Self.enabledKey)
        if enabled {
            await start()
        } else {
            stop()
        }
    }
}
