import Foundation

/// One bounded generation job for ModelService (Stage 1, #64).
///
/// ModelService gets only this snapshot: no database, no collectors, no tools. Collected text inside `user`
/// stays data. The model returns text, and AegisCore alone turns that text into a checked `Brief`.
public struct ModelJob: Codable, Sendable, Hashable {
    /// Limits that keep a job bounded whatever the day held.
    public static let maxSystemBytes = 32 * 1024
    public static let maxUserBytes = 64 * 1024
    public static let maxHistoryBytes = 32 * 1024
    public static let maxOutputTokens = 2000

    /// The request ID: a retry with the same ID is the same job.
    public var id: String
    /// The pinned model, for example `mlx-community/Qwen3.5-4B-MLX-4bit@<revision>`.
    public var model: String
    public var system: String
    public var user: String
    public var maxTokens: Int
    public var deadline: Date
    /// The stored snapshot the input came from, so citations can be checked against exactly that.
    public var inputRevision: String
    /// Earlier exchanges of a conversation, oldest first, given to the model as its own chat turns before `user`
    /// (#52). Only the owner's words and Aegis's checked replies; never collected content.
    public var history: [Exchange]
    /// How the model picks its words (#52).
    public var style: Style

    /// One earlier exchange of a conversation.
    public struct Exchange: Codable, Sendable, Hashable {
        public var owner: String
        public var aegis: String
        public init(owner: String, aegis: String) {
            self.owner = owner
            self.aegis = aegis
        }
    }

    /// `exact` always takes the likeliest word (briefs, JSON, checks); `conversation` samples a little, as Qwen
    /// recommends for chat, so replies read naturally (#52).
    public enum Style: String, Codable, Sendable {
        case exact, conversation
    }

    public init(
        id: String, model: String, system: String, user: String, maxTokens: Int, deadline: Date, inputRevision: String,
        history: [Exchange] = [], style: Style = .exact
    ) {
        self.id = id
        self.model = model
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
        self.deadline = deadline
        self.inputRevision = inputRevision
        self.history = history
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case id, model, system, user, maxTokens, deadline, inputRevision, history, style
    }

    /// A job from a ModelService or AegisCore built before #52 has no history or style.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id), model: container.decode(String.self, forKey: .model),
            system: container.decode(String.self, forKey: .system), user: container.decode(String.self, forKey: .user),
            maxTokens: container.decode(Int.self, forKey: .maxTokens), deadline: container.decode(Date.self, forKey: .deadline),
            inputRevision: container.decode(String.self, forKey: .inputRevision),
            history: container.decodeIfPresent([Exchange].self, forKey: .history) ?? [],
            style: container.decodeIfPresent(Style.self, forKey: .style) ?? .exact
        )
    }

    /// Errors as "field: message" (empty when the job may be sent).
    public func validate() -> [String] {
        var errors: [String] = []
        if id.isEmpty {
            errors.append("id: empty")
        }
        if model.isEmpty {
            errors.append("model: empty")
        }
        if inputRevision.isEmpty {
            errors.append("input_revision: empty")
        }
        if system.utf8.count > Self.maxSystemBytes {
            errors.append("system: over \(Self.maxSystemBytes) bytes")
        }
        if user.utf8.count > Self.maxUserBytes {
            errors.append("user: over \(Self.maxUserBytes) bytes")
        }
        if history.reduce(0, { $0 + $1.owner.utf8.count + $1.aegis.utf8.count }) > Self.maxHistoryBytes {
            errors.append("history: over \(Self.maxHistoryBytes) bytes")
        }
        if !(1 ... Self.maxOutputTokens).contains(maxTokens) {
            errors.append("max_tokens: must be 1 to \(Self.maxOutputTokens)")
        }
        return errors
    }
}

/// What ModelService measured while running a job. Numbers only, never text.
public struct ModelMetrics: Codable, Sendable, Hashable {
    public var loadSeconds: Double?
    public var firstTokenSeconds: Double?
    public var generateSeconds: Double?
    public var promptTokens: Int?
    public var generationTokens: Int?
    public var peakMemoryBytes: Int?

    public init(
        loadSeconds: Double? = nil, firstTokenSeconds: Double? = nil, generateSeconds: Double? = nil,
        promptTokens: Int? = nil, generationTokens: Int? = nil, peakMemoryBytes: Int? = nil
    ) {
        self.loadSeconds = loadSeconds
        self.firstTokenSeconds = firstTokenSeconds
        self.generateSeconds = generateSeconds
        self.promptTokens = promptTokens
        self.generationTokens = generationTokens
        self.peakMemoryBytes = peakMemoryBytes
    }
}

/// The outcome of a `ModelJob`.
public struct ModelJobResult: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case completed, failed, cancelled
        case timedOut = "timed_out"
    }

    /// Why a job failed. Codes only, never model or collected text.
    public enum Failure: String, Codable, Sendable, CaseIterable {
        case modelMissing = "model_missing"
        case modelCorrupt = "model_corrupt"
        case inputTooLarge = "input_too_large"
        case outOfMemory = "out_of_memory"
        case interrupted
        case internalError = "internal_error"
    }

    public var jobID: String
    public var status: Status
    /// The model's raw answer, only when completed. AegisCore validates it before anything is stored.
    public var text: String?
    public var failure: Failure?
    public var metrics: ModelMetrics

    public init(jobID: String, status: Status, text: String? = nil, failure: Failure? = nil, metrics: ModelMetrics = .init()) {
        self.jobID = jobID
        self.status = status
        self.text = text
        self.failure = failure
        self.metrics = metrics
    }

    /// Errors as "field: message": text exactly when completed, a failure code exactly when failed.
    public func validate() -> [String] {
        var errors: [String] = []
        if jobID.isEmpty {
            errors.append("job_id: empty")
        }
        if (status == .completed) != (text != nil) {
            errors.append("text: present exactly when completed")
        }
        if (status == .failed) != (failure != nil) {
            errors.append("failure: present exactly when failed")
        }
        return errors
    }
}
