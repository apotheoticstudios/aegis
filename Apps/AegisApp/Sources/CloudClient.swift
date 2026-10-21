import AegisKit
import Foundation
import OSLog
import Security

/// Why a hand-off didn't answer, as the owner hears it.
struct HandOffProblem: Error {
    let message: String
}

/// Claude and ChatGPT for the hand-off (#223, ADR-0017). Sends exactly what AegisCore's gate approved (the owner's
/// words and earlier non-personal turns of the same hand-off) with the owner's own key from the Keychain, and
/// nothing else. Logs codes only, never text.
actor CloudClient {
    struct Reply: Sendable {
        let text: String
        let model: String
    }

    enum Failure: Error, Sendable {
        case noKey, badKey, busy, offline, declined, cancelled, unwritable, failed(Int)

        func message(_ provider: CloudHandOff.Provider) -> String {
            let name = provider.name
            return switch self {
            case .noKey: "I can't reach \(name) yet: add your \(name) API key under Claude and ChatGPT in Aegis's menu."
            case .badKey: "\(name) didn't accept the API key. Check it under Claude and ChatGPT in Aegis's menu."
            case .busy: "\(name) is busy right now. Try again in a moment."
            case .offline: "I couldn't reach \(name). Check the internet connection."
            case .declined: "\(name) declined to answer that one."
            case .cancelled: "Stopped."
            case .unwritable: "I couldn't save the answer in the task's folder."
            case .failed: "\(name) didn't answer properly. Could you try again?"
            }
        }
    }

    /// Claude's current Opus model (the claude-api skill's default).
    static let claudeModel = "claude-opus-5-5"
    /// When the models list can't be read.
    static let fallbackGPTModel = "gpt-5"

    // privacy-guard: allow-network the owner-enabled Claude/ChatGPT hand-off (#223, ADR-0017)
    private let session: URLSession = { // privacy-guard: allow-network cloud hand-off, owner's key (ADR-0017)
        let config = URLSessionConfiguration.ephemeral // privacy-guard: allow-network cloud hand-off (ADR-0017)
        config.timeoutIntervalForRequest = 120
        config.urlCache = nil
        return URLSession(configuration: config) // privacy-guard: allow-network cloud hand-off (ADR-0017)
    }()

    private var gptModel: String?
    private let log = Logger(subsystem: "dev.aegis.app", category: "cloud")

    func send(_ request: CloudHandOff.Request) async -> Result<Reply, Failure> {
        guard let key = CloudKeys.key(for: request.provider) else {
            DiagnosticLog.shared.record(.cloudFailed)
            return .failure(.noKey)
        }
        let result = switch request.provider {
        case .claude: await claude(request, key: key)
        case .chatgpt: await chatGPT(request, key: key)
        }
        if case let .failure(failure) = result {
            if case let .failed(number) = failure {
                DiagnosticLog.shared.record(.cloudFailed, number: number)
            } else if case .cancelled = failure {} else {
                DiagnosticLog.shared.record(.cloudFailed)
            }
            log.notice("hand-off failed: \(String(describing: failure), privacy: .public)")
        }
        return result
    }

    /// An API task saves only in the checked task folder, and never after Stop.
    func task(_ request: CloudHandOff.Request, in folder: URL, base: URL) async -> Result<String, Failure> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard PlanRunner.validFolder(folder, base: base) else {
            DiagnosticLog.shared.record(.cloudFailed, number: -3)
            return .failure(.unwritable)
        }
        let result = await send(request)
        guard !Task.isCancelled else { return .failure(.cancelled) }
        switch result {
        case let .success(reply):
            guard PlanRunner.validFolder(folder, base: base),
                  (try? reply.text.write(
                      to: folder.appendingPathComponent("\(request.provider.name).md"),
                      atomically: true,
                      encoding: .utf8
                  )) != nil
            else {
                DiagnosticLog.shared.record(.cloudFailed, number: -3)
                return .failure(.unwritable)
            }
            return .success("I've saved \(request.provider.name)'s answer in the task's folder.")
        case let .failure(failure):
            return .failure(failure)
        }
    }

    private func claude(_ request: CloudHandOff.Request, key: String) async -> Result<Reply, Failure> {
        let body: [String: Any] = [
            "model": Self.claudeModel, "max_tokens": 16000, "system": CloudHandOff.instructions,
            "messages": Self.messages(request), "output_config": ["effort": "medium"],
            // A declined request is retried server-side on the model Anthropic recommends for it.
            "fallbacks": "default",
        ]
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { // privacy-guard: allow-network Claude (ADR-0017)
            return .failure(.failed(0))
        }
        var post = URLRequest(url: url) // privacy-guard: allow-network Claude hand-off (ADR-0017)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "content-type")
        post.setValue(key, forHTTPHeaderField: "x-api-key")
        post.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        post.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        post.httpBody = try? JSONSerialization.data(withJSONObject: body)
        switch await json(post) {
        case let .failure(failure):
            return .failure(failure)
        case let .success(object):
            guard object["stop_reason"] as? String != "refusal" else { return .failure(.declined) }
            let blocks = object["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { return .failure(.failed(0)) }
            return .success(Reply(text: text, model: object["model"] as? String ?? Self.claudeModel))
        }
    }

    private func chatGPT(_ request: CloudHandOff.Request, key: String) async -> Result<Reply, Failure> {
        let model = await newestGPT(key: key)
        let body: [String: Any] = [
            "model": model, "max_completion_tokens": 16000,
            "messages": [["role": "system", "content": CloudHandOff.instructions]] + Self.messages(request),
        ]
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { // privacy-guard: allow-network ChatGPT (ADR-0017)
            return .failure(.failed(0))
        }
        var post = URLRequest(url: url) // privacy-guard: allow-network ChatGPT hand-off (ADR-0017)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        post.httpBody = try? JSONSerialization.data(withJSONObject: body)
        switch await json(post) {
        case let .failure(failure):
            return .failure(failure)
        case let .success(object):
            let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            if let refusal = message?["refusal"] as? String, !refusal.isEmpty {
                return .failure(.declined)
            }
            guard let text = message?["content"] as? String, !text.isEmpty else { return .failure(.failed(0)) }
            return .success(Reply(text: text, model: object["model"] as? String ?? model))
        }
    }

    /// The newest flagship GPT model the key can use ("gpt-5.5" over "gpt-5"), read once from the models list.
    private func newestGPT(key: String) async -> String {
        if let gptModel {
            return gptModel
        }
        var chosen = Self.fallbackGPTModel
        if let url = URL(string: "https://api.openai.com/v1/models") { // privacy-guard: allow-network ChatGPT models list (ADR-0017)
            var get = URLRequest(url: url) // privacy-guard: allow-network ChatGPT models list (ADR-0017)
            get.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            if case let .success(object) = await json(get), let models = object["data"] as? [[String: Any]] {
                let ids = models.compactMap { $0["id"] as? String }
                chosen = Self.newest(ids) ?? chosen
            }
        }
        gptModel = chosen
        return chosen
    }

    /// "gpt-5.5" from ["gpt-5", "gpt-5.5", "gpt-5.5-mini", "gpt-4o"]: plain flagship names only.
    static func newest(_ ids: [String]) -> String? {
        let versions = ids.compactMap { id -> (String, Int, Int)? in
            guard let match = id.range(of: #"^gpt-(\d+)(?:\.(\d+))?$"#, options: .regularExpression), match == id.startIndex ..< id.endIndex
            else { return nil }
            let parts = id.dropFirst(4).split(separator: ".").compactMap { Int($0) }
            return (id, parts.first ?? 0, parts.count > 1 ? parts[1] : 0)
        }
        return versions.max { ($0.1, $0.2) < ($1.1, $1.2) }?.0
    }

    private static func messages(_ request: CloudHandOff.Request) -> [[String: Any]] {
        request.history.flatMap { [["role": "user", "content": $0.owner], ["role": "assistant", "content": $0.reply]] }
            + [["role": "user", "content": request.question]]
    }

    private func json(_ request: URLRequest) async -> Result<[String: Any], Failure> { // privacy-guard: allow-network (ADR-0017)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200 ..< 300:
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .failure(.failed(status))
                }
                return .success(object)
            case 401, 403: return .failure(.badKey)
            case 408, 429, 500 ..< 600: return .failure(.busy)
            default: return .failure(.failed(status))
            }
        } catch {
            DiagnosticLog.shared.record(.cloudFailed, number: (error as NSError).code)
            return .failure(.offline)
        }
    }
}

/// The owner's Claude and OpenAI API keys, in the Mac's Keychain only (#223), and the automatic hand-off setting.
enum CloudKeys {
    private static let service = "dev.jarvis.cloud" // kept: existing Keychain items (ADR-0028)
    static let automaticKey = "cloudHandOffAutomatic"

    static func key(for provider: CloudHandOff.Provider) -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    /// Saves a key, or removes it when empty. False when the Keychain refused.
    @discardableResult
    static func set(_ key: String, for provider: CloudHandOff.Provider) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                DiagnosticLog.shared.record(.cloudFailed, number: Int(status))
                return false
            }
            UserDefaults.standard.set(false, forKey: savedKey + provider.rawValue)
            return true
        }
        let values: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(base as CFDictionary, values as CFDictionary)
        if updated == errSecSuccess {
            UserDefaults.standard.set(true, forKey: savedKey + provider.rawValue)
            return true
        }
        guard updated == errSecItemNotFound else {
            DiagnosticLog.shared.record(.cloudFailed, number: Int(updated))
            return false
        }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Aegis: \(provider.name) API key"
        let status = SecItemAdd(add as CFDictionary, nil)
        let saved = status == errSecSuccess
        if saved {
            UserDefaults.standard.set(true, forKey: savedKey + provider.rawValue)
        } else {
            DiagnosticLog.shared.record(.cloudFailed, number: Int(status))
        }
        return saved
    }

    private static let savedKey = "cloudKeySaved."

    /// Whether a key was saved, without touching the Keychain: asking runs on the main thread, and the Keychain is
    /// read only when a hand-off is sent.
    static func hasKey(_ provider: CloudHandOff.Provider) -> Bool {
        UserDefaults.standard.bool(forKey: savedKey + provider.rawValue)
    }

    static let planKey = "cloudUseChatGPTPlan"

    /// Use the owner's ChatGPT plan through the ChatGPT app when there's no OpenAI key (#235). On unless turned off.
    static var useChatGPTPlan: Bool {
        get { UserDefaults.standard.object(forKey: planKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: planKey) }
    }

    /// The provider answers through the owner's plan app rather than an API key.
    static func viaPlan(_ provider: CloudHandOff.Provider) -> Bool {
        provider == .chatgpt && !hasKey(.chatgpt) && useChatGPTPlan && PlanRunner.codex != nil
    }

    static var automatic: Bool {
        get { UserDefaults.standard.bool(forKey: automaticKey) }
        set { UserDefaults.standard.set(newValue, forKey: automaticKey) }
    }

    /// What the panel tells AegisCore it can hand off to: Claude first when both have keys.
    static var availability: CloudHandOff.Availability {
        .init(providers: CloudHandOff.Provider.allCases.filter { hasKey($0) || viaPlan($0) }, automatic: automatic)
    }
}
