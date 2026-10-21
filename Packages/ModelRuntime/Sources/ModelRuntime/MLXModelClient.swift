import AegisKit
import Darwin
import Foundation
import MLX
import MLXEmbedders
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Runs model jobs with MLX: Qwen3.5 (4B or 9B by the Mac's memory), 4-bit, greedy decoding with thinking off, from a local folder
/// (no downloader, no network). It loads on the first job and stays loaded until ModelService exits after
/// its idle time, which returns the memory (ADR-0013). Collected text in a job is data for the model; the
/// answer goes back to AegisCore, which checks it before anything is stored. Never logs either.
public actor MLXModelClient: ModelClient {
    private let folder: URL?
    private var container: ModelContainer?
    private var embedder: EmbedderModelContainer?
    private var cancelled: Set<String> = []
    /// Each running job's text so far (#263).
    private var partials: [String: String] = [:]

    /// The most freed GPU memory MLX may keep for reuse between steps.
    static let cacheLimit = 256 * 1024 * 1024

    /// `folder` nil means the model isn't installed: every job fails with `model_missing`.
    public init(folder: URL?) {
        self.folder = folder
    }

    public func run(_ job: ModelJob) async throws -> ModelJobResult {
        guard job.validate().isEmpty else {
            return ModelJobResult(jobID: job.id, status: .failed, failure: .inputTooLarge)
        }
        guard let folder else {
            return ModelJobResult(jobID: job.id, status: .failed, failure: .modelMissing)
        }
        var metrics = ModelMetrics()
        // MLX keeps freed buffers for reuse; uncapped, a brief pushed the process to about 5.7 GB (#174).
        Memory.cacheLimit = Self.cacheLimit
        let model: ModelContainer
        if let loaded = container {
            model = loaded
        } else {
            let start = Date()
            do {
                model = try await LLMModelFactory.shared.loadContainer(from: folder, using: LocalTokenizerLoader())
            } catch {
                return ModelJobResult(jobID: job.id, status: .failed, failure: .modelCorrupt)
            }
            container = model
            metrics.loadSeconds = Date().timeIntervalSince(start)
        }
        Memory.peakMemory = 0
        let begin = Date()
        var text = ""
        defer { partials[job.id] = nil }
        do {
            let input = UserInput(
                chat: [.system(job.system), .user(job.user)], additionalContext: ["enable_thinking": false]
            )
            let prepared = try await model.prepare(input: input)
            let parameters = GenerateParameters(maxTokens: job.maxTokens, temperature: 0)
            for await item in try await model.generate(input: prepared, parameters: parameters) {
                if cancelled.remove(job.id) != nil {
                    return ModelJobResult(jobID: job.id, status: .cancelled, metrics: finish(metrics, begin))
                }
                if Date() >= job.deadline {
                    return ModelJobResult(jobID: job.id, status: .timedOut, metrics: finish(metrics, begin))
                }
                switch item {
                case let .chunk(chunk):
                    if metrics.firstTokenSeconds == nil {
                        metrics.firstTokenSeconds = Date().timeIntervalSince(begin)
                    }
                    text += chunk
                    partials[job.id] = text
                case let .info(info):
                    metrics.promptTokens = info.promptTokenCount
                    metrics.generationTokens = info.generationTokenCount
                default:
                    break
                }
            }
        } catch {
            return ModelJobResult(jobID: job.id, status: .failed, failure: .internalError, metrics: finish(metrics, begin))
        }
        if cancelled.remove(job.id) != nil {
            return ModelJobResult(jobID: job.id, status: .cancelled, metrics: finish(metrics, begin))
        }
        return ModelJobResult(jobID: job.id, status: .completed, text: text, metrics: finish(metrics, begin))
    }

    public func cancel(jobID: String) async {
        cancelled.insert(jobID)
    }

    public func partial(jobID: String) async -> String? {
        partials[jobID]
    }

    private func finish(_ metrics: ModelMetrics, _ begin: Date) -> ModelMetrics {
        var metrics = metrics
        metrics.generateSeconds = Date().timeIntervalSince(begin)
        metrics.peakMemoryBytes = Memory.peakMemory
        return metrics
    }
}

/// swift-transformers' tokenizer behind mlx-swift-lm's protocol (as in the spike, without macros).
struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? {
        upstream.bosToken
    }

    var eosToken: String? {
        upstream.eosToken
    }

    var unknownToken: String? {
        upstream.unknownToken
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Memory recall by meaning (#309): bge-small-en-v1.5 (MIT), loaded on first use from Aegis's folder and unloaded with
/// ModelService. Only the owner's notes and questions are embedded; vectors go back to AegisCore, nothing is kept here.
public extension MLXModelClient {
    func embed(_ texts: [String]) async -> [[Float]]? {
        guard !texts.isEmpty else { return [] }
        guard let embedder = await loadedEmbedder() else { return nil }
        var vectors: [[Float]] = []
        for start in stride(from: 0, to: texts.count, by: 64) {
            let batch = Array(texts[start ..< min(start + 64, texts.count)])
            let part = await embedder.perform { context -> [[Float]] in
                // BERT's [PAD] is 0, so padding and the attention mask come from the same zeros.
                let inputs = batch.map { Array(context.tokenizer.encode(text: $0, addSpecialTokens: true).prefix(256)) }
                let length = max(inputs.map(\.count).max() ?? 1, 1)
                let padded = stacked(inputs.map { MLXArray($0 + Array(repeating: 0, count: length - $0.count)) })
                let mask = padded .!= 0
                let output = context.model(padded, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: padded), attentionMask: mask)
                let pooled = context.pooling(output, mask: mask, normalize: true)
                pooled.eval()
                return pooled.map { $0.asArray(Float.self) }
            }
            vectors += part
        }
        return vectors.count == texts.count ? vectors : nil
    }
}

extension MLXModelClient {
    func loadedEmbedder() async -> EmbedderModelContainer? {
        if let embedder {
            return embedder
        }
        let folder = ModelLocation.meaningFolder
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.safetensors").path) else { return nil }
        embedder = try? await EmbedderModelFactory.shared.loadContainer(from: folder, using: LocalTokenizerLoader())
        return embedder
    }
}

struct LocalTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        try await TokenizerBridge(upstream: AutoTokenizer.from(modelFolder: directory))
    }
}
