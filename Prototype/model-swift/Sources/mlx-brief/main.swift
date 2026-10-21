// mlx-brief MODEL_DIR SPEC.json [SPEC.json ...]
//
// Loads the model once from a local folder (no downloader, no network), then for each spec
// ({"system", "user", "max_tokens"}) writes one brief with greedy decoding, the same way
// Prototype/model/mlx_worker.py does in Python. Prints one JSON line per spec with timings,
// memory and the answer, then one line with the memory left after the model is released.
// Fake data only: the specs come from the synthetic fixtures.

import Darwin
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// swift-transformers' tokenizer behind mlx-swift-lm's protocol (the same mapping as its
/// MLXHuggingFace macros, written out to avoid the macro dependency).
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
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

struct LocalTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        try await TokenizerBridge(upstream: AutoTokenizer.from(modelFolder: directory))
    }
}

struct Spec: Decodable {
    let system: String
    let user: String
    let max_tokens: Int?
}

/// The process's dirty memory footprint (what Activity Monitor calls Memory), in GB.
func footprintGB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_073_741_824 : -1
}

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: mlx-brief MODEL_DIR SPEC.json [SPEC.json ...]\n".utf8))
    exit(2)
}

let modelDirectory = URL(fileURLWithPath: arguments[1])
let footprintBefore = footprintGB()
let loadStart = Date()
var container: ModelContainer? = try await LLMModelFactory.shared.loadContainer(
    from: modelDirectory, using: LocalTokenizerLoader()
)
let loadSeconds = Date().timeIntervalSince(loadStart)
emit([
    "event": "loaded",
    "load_s": loadSeconds,
    "footprint_gb": footprintGB(),
    "footprint_before_gb": footprintBefore,
])

for path in arguments.dropFirst(2) {
    let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    Memory.peakMemory = 0
    let input = UserInput(
        chat: [.system(spec.system), .user(spec.user)],
        additionalContext: ["enable_thinking": false]
    )
    let begin = Date()
    let prepared = try await container!.prepare(input: input)
    let parameters = GenerateParameters(maxTokens: spec.max_tokens ?? 700, temperature: 0)
    var text = ""
    var first: Double?
    var info: GenerateCompletionInfo?
    for await item in try await container!.generate(input: prepared, parameters: parameters) {
        switch item {
        case let .chunk(chunk):
            if first == nil {
                first = Date().timeIntervalSince(begin)
            }
            text += chunk
        case let .info(completion):
            info = completion
        default:
            break
        }
    }
    let total = Date().timeIntervalSince(begin)
    emit([
        "event": "brief", "spec": path, "first_token_s": first ?? -1, "generate_s": total,
        "prompt_tokens": info?.promptTokenCount ?? -1,
        "prompt_tps": info.map { Double($0.promptTokenCount) / max($0.promptTime, 1e-9) } ?? -1,
        "generation_tokens": info?.generationTokenCount ?? -1,
        "generation_tps": info.map { Double($0.generationTokenCount) / max($0.generateTime, 1e-9) } ?? -1,
        "mlx_peak_gb": Double(Memory.peakMemory) / 1_073_741_824,
        "footprint_gb": footprintGB(), "text": text,
    ])
}

// Release the model inside this long-lived process, the way an on-demand ModelService would
// after an idle timeout, and see how much memory comes back without the process exiting.
container = nil
Memory.clearCache()
try await Task.sleep(nanoseconds: 3_000_000_000)
emit([
    "event": "released",
    "footprint_gb": footprintGB(),
    "mlx_active_gb": Double(Memory.activeMemory) / 1_073_741_824,
    "mlx_cache_gb": Double(Memory.cacheMemory) / 1_073_741_824,
])
