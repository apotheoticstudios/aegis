import Foundation
import SherpaOnnxC

/// A local, wake-keyword detector. It exposes only a wake match, never arbitrary speech text.
/// Confine an instance to one serial worker; no microphone, files, logs or network are used after initialization.
public final class KeywordDetector {
    private let spotter: OpaquePointer
    private var stream: OpaquePointer

    /// Opens the bundled, verified model with "Hey Aegis" and an optional one-word English wake name. Missing assets fail closed.
    public init?(directory: URL, additionalName: String? = nil) {
        let names = ["encoder.int8.onnx", "decoder.onnx", "joiner.int8.onnx", "tokens.txt", "keywords.txt"]
        let paths = names.map { directory.appendingPathComponent($0).path }
        guard paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else { return nil }
        // Keep every C string alive until construction copies the configuration.
        guard let keywords = KeywordTokens.keywords(directory: directory, name: additionalName) else { return nil }
        let strings = (paths + ["cpu", keywords, ""]).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else { return nil }
        var config = SherpaOnnxKeywordSpotterConfig()
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = UnsafePointer(strings[0])
        config.model_config.transducer.decoder = UnsafePointer(strings[1])
        config.model_config.transducer.joiner = UnsafePointer(strings[2])
        config.model_config.tokens = UnsafePointer(strings[3])
        config.model_config.provider = UnsafePointer(strings[5])
        config.model_config.num_threads = 1
        config.model_config.debug = 0
        config.max_active_paths = 4
        config.num_trailing_blanks = 1
        config.keywords_score = 1.5
        // Lower than sherpa-onnx's 0.25: the owner's "Hey Aegis" was often missed (#303).
        config.keywords_threshold = 0.18
        config.keywords_file = UnsafePointer(strings[7])
        config.keywords_buf = UnsafePointer(strings[6])
        config.keywords_buf_size = Int32(keywords.utf8.count)
        guard let spotter = SherpaOnnxCreateKeywordSpotter(&config) else { return nil }
        guard let stream = SherpaOnnxCreateKeywordStream(spotter) else {
            SherpaOnnxDestroyKeywordSpotter(spotter)
            return nil
        }
        self.spotter = spotter
        self.stream = stream
    }

    deinit {
        SherpaOnnxDestroyOnlineStream(stream)
        SherpaOnnxDestroyKeywordSpotter(spotter)
    }

    /// Consumes a short mono PCM chunk in memory and returns only whether the configured keyword occurred.
    public func accept(_ samples: [Float], sampleRate: Int) -> Bool {
        guard (8000 ... 192_000).contains(sampleRate), !samples.isEmpty, samples.count <= sampleRate else { return false }
        SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), samples, Int32(samples.count))
        while SherpaOnnxIsKeywordStreamReady(spotter, stream) != 0 {
            SherpaOnnxDecodeKeywordStream(spotter, stream)
            guard let result = SherpaOnnxGetKeywordResult(spotter, stream) else { continue }
            let matched = result.pointee.keyword.map { $0.pointee != 0 } ?? false
            SherpaOnnxDestroyKeywordResult(result)
            if matched {
                reset()
                return true
            }
        }
        return false
    }

    /// Discards all acoustic state between listening windows, including any partially matched wake phrase.
    public func reset() {
        guard let replacement = SherpaOnnxCreateKeywordStream(spotter) else { return }
        SherpaOnnxDestroyOnlineStream(stream)
        stream = replacement
    }
}
