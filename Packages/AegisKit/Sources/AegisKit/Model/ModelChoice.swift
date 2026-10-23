import Foundation

/// Which local model a Mac runs, decided by its memory (DESIGN.md "RAM decides what runs"). Both are Qwen3.5,
/// MLX 4-bit, pinned revisions; Aegis's checks and rules after the model apply to either (#190).
public struct ModelChoice: Sendable, Hashable {
    /// The Hugging Face repository, e.g. `mlx-community/Qwen3.5-9B-MLX-4bit`.
    public let repository: String
    /// The pinned revision (a commit hash).
    public let revision: String
    /// The short name stored with briefs and answers.
    public let name: String

    /// Qwen3.5-4B: the 16 GB Mac's model (ADR-0009). About 3.8 GB at peak.
    public static let small = ModelChoice(
        repository: "mlx-community/Qwen3.5-4B-MLX-4bit", revision: "32f3e8ecf65426fc3306969496342d504bfa13f3",
        name: "qwen3.5-4b-4bit"
    )
    /// Qwen3.5-9B: for Macs with 24 GB or more. About 6.4 GB at peak.
    public static let medium = ModelChoice(
        repository: "mlx-community/Qwen3.5-9B-MLX-4bit", revision: "938d8919941c6e7efd3c7150eff7fe9d12afa631",
        name: "qwen3.5-9b-4bit"
    )

    /// The model for this much memory: 24 GB or more runs the 9B, otherwise the 4B.
    public static func forMemory(_ bytes: UInt64) -> ModelChoice {
        bytes >= 24 * 1_000_000_000 ? medium : small
    }

    /// The model for this Mac: the tune-up's choice (ADR-0030), otherwise the one its memory runs.
    public static var current: ModelChoice {
        aegisFolder.flatMap(chosen(in:)) ?? forMemory(ProcessInfo.processInfo.physicalMemory)
    }

    /// The folder name the repository's files live in (`Qwen3.5-9B-MLX-4bit`).
    public var folderName: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }
}
