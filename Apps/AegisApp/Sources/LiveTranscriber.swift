import AVFoundation
import Speech

// SpeechAnalyzer arrived with the macOS 26 SDK (Swift 6.2); older toolchains build the older recogniser only.
#if compiler(>=6.2)

    /// Live, on-device transcription with Apple's SpeechAnalyzer (#213): quicker than the older recogniser, with the
    /// words as they're spoken and the final words when the owner pauses. The mic button and "Hey Aegis" both use
    /// it; on a Mac without it they fall back to SFSpeechRecognizer. Audio never leaves the Mac; nothing is kept.
    @available(macOS 26, *)
    final class LiveTranscriber: SpeechSession, @unchecked Sendable {
        let isLegacy = false
        private let lock = NSLock()
        private var input: AsyncStream<AnalyzerInput>.Continuation?
        private var format: AVAudioFormat?
        private var converter: AVAudioConverter?
        private var analyzer: SpeechAnalyzer?
        private var reading: Task<Void, Never>?
        private var cancelled = false
        private var finishing = false
        private var conversionReported = false
        private var receivedFrames = 0
        private var producedFrames = 0
        private var failed = false

        /// Apple's on-device model for the owner's English, installed if it isn't yet. Nil when this Mac can't.
        static func transcriber() async -> SpeechTranscriber? {
            guard SpeechTranscriber.isAvailable else { return nil }
            for id in [Locale.current.identifier, "en-AU", "en-GB", "en-US"] {
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else { continue }
                let transcriber = SpeechTranscriber(
                    locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: []
                )
                if await AssetInventory.status(forModules: [transcriber]) < .installed,
                   let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])
                {
                    do { try await request.downloadAndInstall() }
                    catch { DiagnosticLog.shared.record(.speechSetupFailed, number: (error as NSError).code) }
                }
                if await AssetInventory.status(forModules: [transcriber]) == .installed {
                    return transcriber
                }
            }
            return nil
        }

        /// Starts a session. `heard` gets the words so far and whether they're final, on the main actor.
        @MainActor
        func start(heard: @escaping @MainActor @Sendable (String, Bool) -> Void) async -> Bool {
            guard let transcriber = await Self.transcriber() else {
                DiagnosticLog.shared.record(.speechSetupFailed, detail: 1)
                return false
            }
            guard lock.withLock({ !cancelled }) else { return false }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                DiagnosticLog.shared.record(.speechSetupFailed, detail: 2)
                return false
            }
            do {
                try await analyzer.prepareToAnalyze(in: format)
            } catch {
                DiagnosticLog.shared.record(.speechSetupFailed, number: (error as NSError).code)
                return false
            }
            guard lock.withLock({ !cancelled }) else { await analyzer.cancelAndFinishNow(); return false }
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            lock.withLock {
                input = continuation
                self.format = format
                converter = nil
                self.analyzer = analyzer
            }
            reading = Task {
                var finished = ""
                do {
                    for try await result in transcriber.results {
                        guard !Task.isCancelled else { return }
                        let words = String(result.text.characters)
                        if result.isFinal {
                            finished += words
                            await heard(finished.trimmingCharacters(in: .whitespaces), false)
                        } else {
                            await heard((finished + words).trimmingCharacters(in: .whitespaces), false)
                        }
                    }
                } catch {
                    DiagnosticLog.shared.record(.speechResultFailed, number: (error as NSError).code)
                    guard !Task.isCancelled else { return }
                    await heard("", true)
                    return
                }
                guard !Task.isCancelled else { return }
                let didFail = lock.withLock { failed }
                await heard(didFail ? "" : finished.trimmingCharacters(in: .whitespaces), true)
            }
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                DiagnosticLog.shared.record(.speechSetupFailed, number: (error as NSError).code)
                await cancel()
                return false
            }
            return true
        }

        /// Microphone audio from the audio thread, converted to the model's format.
        func feed(_ buffer: AVAudioPCMBuffer) {
            guard let buffer = SpeechAudio.voiceChannel(buffer) else { return }
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled, let input, let format else { return }
            if receivedFrames == 0 {
                DiagnosticLog.shared.record(
                    .speechInputFormat,
                    number: Int(buffer.format.sampleRate),
                    detail: Int(buffer.format.channelCount)
                )
            }
            receivedFrames += Int(buffer.frameLength)
            guard buffer.format != format else {
                producedFrames += Int(buffer.frameLength)
                input.yield(AnalyzerInput(buffer: buffer))
                return
            }
            if converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: format)
            }
            guard let converter,
                  let converted = AVAudioPCMBuffer(
                      pcmFormat: format,
                      frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
                  )
            else {
                if !conversionReported {
                    DiagnosticLog.shared.record(.speechConversionFailed); conversionReported = true
                }
                return
            }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if let error, !conversionReported {
                conversionReported = true
                DiagnosticLog.shared.record(.speechConversionFailed, number: error.code)
            }
            if error == nil, converted.frameLength > 0 {
                producedFrames += Int(converted.frameLength)
                input.yield(AnalyzerInput(buffer: converted))
            }
        }

        /// The owner paused: finish the words (the final call to `heard` follows).
        @MainActor
        func finish() async {
            let (input, analyzer) = lock.withLock {
                guard !finishing, self.analyzer != nil else { return (
                    nil as AsyncStream<AnalyzerInput>.Continuation?,
                    nil as SpeechAnalyzer?
                ) }
                finishing = true
                if receivedFrames > 0, producedFrames == 0 {
                    DiagnosticLog.shared.record(.speechConversionFailed, detail: receivedFrames)
                }
                return (self.input, self.analyzer)
            }
            input?.finish()
            do { try await analyzer?.finalizeAndFinishThroughEndOfInput() }
            catch {
                lock.withLock { failed = true }
                DiagnosticLog.shared.record(.speechFinalizeFailed, number: (error as NSError).code)
                await analyzer?.cancelAndFinishNow()
            }
            lock.withLock { self.input = nil }
        }

        /// Stops at once, without final words.
        @MainActor
        func cancel() async {
            let (input, analyzer) = lock.withLock { cancelled = true; return (self.input, self.analyzer) }
            reading?.cancel()
            input?.finish()
            await analyzer?.cancelAndFinishNow()
            lock.withLock { self.input = nil }
        }
    }
#endif
