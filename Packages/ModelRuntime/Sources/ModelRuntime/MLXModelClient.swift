import AegisKit
import Darwin
import Foundation
import MLX
import MLXEmbedders
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Runs model jobs with MLX: Qwen3.5 (4B or 9B by the Mac's memory), 4-bit, thinking off, from a local folder
/// (no downloader, no network). Greedy decoding, except conversation jobs, which sample as Qwen recommends for chat
/// (#52). It loads on the first job and stays loaded until ModelService exits after its idle time, which returns the
/// memory (ADR-0013), and with it the read prefixes it keeps. Collected text in a job is data for the model; the
/// answer goes back to AegisCore, which checks it before anything is stored. Never logs either.
public actor MLXModelClient: ModelClient {
    private let folder: URL?
    private var container: ModelContainer?
    private var embedder: EmbedderModelContainer?
    private var cancelled: Set<String> = []
    /// Each running job's text so far (#263).
    private var partials: [String: String] = [:]
    /// Prompt prefixes already read (instructions and earlier turns), newest last, so the next turn reads only
    /// what's new (#52). Each one is the model's cache after its tokens; at most `keptPrefixes`.
    private var prefixes: [Prefix] = []
    static let keptPrefixes = 3

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
            let turns: [MLXLMCommon.Chat.Message] = job.history.flatMap { [.user($0.owner), .assistant($0.aegis)] }
            let input = UserInput(
                chat: [.system(job.system)] + turns + [.user(job.user)], additionalContext: ["enable_thinking": false]
            )
            let tokens = try await model.prepare(input: input).text.tokens.asArray(Int.self)
            let parameters = Self.parameters(job)
            let reused = prefixes.filter { $0.tokens.count < tokens.count && tokens.starts(with: $0.tokens) }
                .max { $0.tokens.count < $1.tokens.count }
            let (stream, read) = try await model.perform { context in
                try Self.generate(tokens, reusing: reused, parameters: parameters, context: context)
            }
            if let read {
                keep(read)
            } else if let reused {
                keep(reused)
            }
            for await item in stream {
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
                    // The whole prompt, read now or in an earlier turn.
                    metrics.promptTokens = tokens.count
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

    /// Exact for briefs, JSON and checks; for conversation, Qwen3.5's recommended non-thinking chat settings (#52).
    static func parameters(_ job: ModelJob) -> GenerateParameters {
        switch job.style {
        case .exact:
            GenerateParameters(maxTokens: job.maxTokens, temperature: 0)
        case .conversation:
            GenerateParameters(maxTokens: job.maxTokens, temperature: 0.7, topP: 0.8, topK: 20, presencePenalty: 1.5)
        }
    }

    /// Starts generation, reading only the tokens after `reused`. Before the job's last owner turn the cache is
    /// copied as a new read prefix: the next turn's prompt starts with exactly those tokens.
    private static func generate(
        _ tokens: [Int], reusing reused: Prefix?, parameters: GenerateParameters, context: ModelContext
    ) throws -> (AsyncStream<Generation>, Prefix?) {
        let cache = try reused?.cache.map { $0.copy() } ?? context.model.newCache(parameters: parameters)
        var start = reused?.tokens.count ?? 0
        var read: Prefix?
        if let end = lastOwnerTurn(tokens, tokenizer: context.tokenizer), end > start {
            for chunk in stride(from: start, to: end, by: 512) {
                _ = context.model(MLXArray(Array(tokens[chunk ..< min(chunk + 512, end)]))[.newAxis], cache: cache)
                eval(cache)
            }
            let copy = cache.map { $0.copy() }
            eval(copy)
            read = Prefix(tokens: Array(tokens[..<end]), cache: copy)
            start = end
        }
        let rest = LMInput(tokens: MLXArray(Array(tokens[start...])))
        return try (MLXLMCommon.generate(input: rest, cache: cache, parameters: parameters, context: context), read)
    }

    /// Where the last `<|im_start|>user` begins (Qwen's chat format): everything before it is the instructions and
    /// earlier turns, which the next turn repeats. Nil for any other format, which then isn't cached.
    static func lastOwnerTurn(_ tokens: [Int], tokenizer: any MLXLMCommon.Tokenizer) -> Int? {
        guard let start = tokenizer.convertTokenToId("<|im_start|>"),
              let user = tokenizer.encode(text: "user", addSpecialTokens: false).first, tokens.count > 1
        else { return nil }
        return (0 ..< tokens.count - 1).last { tokens[$0] == start && tokens[$0 + 1] == user }
    }

    /// Keeps a read prefix as the newest, dropping any it extends and the oldest past `keptPrefixes`.
    private func keep(_ read: Prefix) {
        prefixes.removeAll { $0 === read || (read.tokens.count >= $0.tokens.count && read.tokens.starts(with: $0.tokens)) }
        prefixes.append(read)
        prefixes = Array(prefixes.suffix(Self.keptPrefixes))
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

/// A read prompt prefix: its tokens and the model's cache after them. The cache is only copied, never written, and
/// only inside the model's `perform`, one job at a time.
final class Prefix: @unchecked Sendable {
    let tokens: [Int]
    let cache: [KVCache]

    init(tokens: [Int], cache: [KVCache]) {
        self.tokens = tokens
        self.cache = cache
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
/// ModelService. Owner notes/questions and bounded record excerpts (ADR-0033) are embedded locally; vectors return to AegisCore.
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
