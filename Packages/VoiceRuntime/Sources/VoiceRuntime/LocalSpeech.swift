import Foundation
import KokoroCoreML

/// Aegis's bundled Kokoro voice. All inference is local; no speech history, external app or server.
/// Call `stop()` when the panel closes. A cancelled inference is discarded and drains before a new model loads.
public actor LocalSpeech {
    private let makeModel: @Sendable () async throws -> any SpeechModel
    private var model: (any SpeechModel)?
    private var loading: (id: UUID, task: Task<(any SpeechModel)?, Never>)?
    private var generating: Task<Data?, Never>?
    private var draining: Task<Void, Never>?
    private var revision = 0

    /// Uses only the model resources packaged inside Aegis; missing resources use the system-voice fallback.
    public init(models: URL? = Bundle.main.resourceURL?.appendingPathComponent("VoiceModels")) {
        makeModel = {
            guard let models else { throw CocoaError(.fileNoSuchFile) }
            let model = try KokoroModel(directory: models)
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !model.ready {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw CocoaError(.coderReadCorrupt) }
                try await Task.sleep(for: .milliseconds(25))
            }
            try Task.checkCancellation()
            return model
        }
    }

    init(makeModel: @escaping @Sendable () async throws -> any SpeechModel) {
        self.makeModel = makeModel
    }

    /// Loads the voice while the panel is open. Concurrent calls share a single load.
    public func prepare() async -> Bool {
        let current = revision
        await draining?.value
        guard current == revision, !Task.isCancelled else { return false }
        draining = nil
        if model != nil {
            return true
        }
        if loading == nil {
            let makeModel = makeModel
            loading = (UUID(), Task.detached(priority: .userInitiated) { try? await makeModel() })
        }
        guard let pending = loading else { return false }
        let loaded = await pending.task.value
        guard current == revision, !Task.isCancelled else { return false }
        if loading?.id == pending.id {
            model = loaded
            loading = nil
        }
        return loaded != nil
    }

    /// Produces an in-memory WAV for a short passage, or nil for system-voice fallback.
    public func audio(for text: String) async -> Data? {
        guard !text.isEmpty, text.count <= 1200, !Task.isCancelled, await prepare(), let model,
              generating == nil else { return nil }
        let current = revision
        let pending = Task.detached(priority: .userInitiated) { () -> Data? in
            guard !Task.isCancelled else { return nil }
            return try? model.audio(for: text)
        }
        generating = pending
        let audio = await withTaskCancellationHandler {
            await pending.value
        } onCancel: {
            pending.cancel()
        }
        guard current == revision else { return nil }
        generating = nil
        return Task.isCancelled || pending.isCancelled ? nil : audio
    }

    /// Discards pending output and releases the model. CoreML finishes any in-flight prediction before release.
    /// Reopening waits for that work, preventing duplicate models and stale audio.
    public func stop() {
        revision += 1
        let load = loading?.task
        let generation = generating
        let previous = draining
        // CoreML warm-up cannot be interrupted. Drain it before allowing another model to load.
        generation?.cancel()
        loading = nil
        generating = nil
        model = nil
        draining = Task {
            await previous?.value
            _ = await load?.value
            _ = await generation?.value
        }
    }
}

protocol SpeechModel: Sendable {
    func audio(for text: String) throws -> Data
}

private final class KokoroModel: SpeechModel {
    private let engine: KokoroEngine
    var ready: Bool {
        engine.isReady
    }

    init(directory: URL) throws {
        // This initializer only opens local files. Never call KokoroEngine.download().
        engine = try KokoroEngine(modelDirectory: directory)
    }

    func audio(for text: String) throws -> Data {
        let result = try engine.synthesize(text: text, voice: "bm_george")
        return try SpeechWave.encode(result.samples)
    }
}

/// A short 24 kHz mono PCM WAV, kept entirely in memory.
enum SpeechWave {
    static func encode(_ samples: [Float]) throws -> Data {
        guard !samples.isEmpty, samples.count <= 24000 * 120 else { throw CocoaError(.coderInvalidValue) }
        var wave = Data()
        func word(_ value: UInt16) {
            var value = value.littleEndian; withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) }
        }
        func integer(_ value: UInt32) {
            var value = value.littleEndian; withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) }
        }
        let size = UInt32(samples.count * 2)
        wave.append(contentsOf: "RIFF".utf8); integer(36 + size)
        wave.append(contentsOf: "WAVEfmt ".utf8); integer(16)
        word(1); word(1); integer(24000); integer(48000); word(2); word(16)
        wave.append(contentsOf: "data".utf8); integer(size)
        for sample in samples {
            let value = sample.isFinite ? max(-1, min(1, sample)) : 0
            word(UInt16(bitPattern: Int16(value * 32767)))
        }
        return wave
    }
}
