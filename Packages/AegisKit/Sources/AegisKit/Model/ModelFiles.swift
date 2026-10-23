import Foundation

/// A model's pinned files (ADR-0030): what setup downloads from Hugging Face into Aegis's Models folder, each file
/// checked by SHA-256 before it takes its real name.
public struct ModelFiles: Sendable, Hashable {
    public struct File: Sendable, Hashable {
        public let path: String
        public let bytes: Int64
        public let sha256: String
    }

    public let repository: String
    public let revision: String
    /// The folder under Aegis's Models folder.
    public let folderName: String
    /// In download order. The file ModelService looks for comes last (`config.json`, or the meaning model's
    /// `model.safetensors`), so a folder is only found once every file in it is in place and checked.
    public let files: [File]

    public var bytes: Int64 {
        files.reduce(0) { $0 + $1.bytes }
    }

    /// Where a file comes from, at the pinned revision.
    public func source(_ file: File) -> URL? {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)") // privacy-guard: allow-network ADR-0030
    }

    /// The memory meaning model (ADR-0027), as `scripts/fetch-meaning-model.sh` fetches it.
    public static let meaning = ModelFiles(
        repository: "BAAI/bge-small-en-v1.5", revision: "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a",
        folderName: "bge-small-en-v1.5", files: [
            File("config.json", 743, "094f8e891b932f2000c92cfc663bac4c62069f5d8af5b5278c4306aef3084750"),
            File("tokenizer.json", 711_396, "d241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66"),
            File("tokenizer_config.json", 366, "9261e7d79b44c8195c1cada2b453e55b00aeb81e907a6664974b4d7776172ab3"),
            File("special_tokens_map.json", 125, "b6d346be366a7d1d48332dbc9fdf3bf8960b5d879522b7799ddba59e76237ee3"),
            File("vocab.txt", 231_508, "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3"),
            File("modules.json", 349, "84e40c8e006c9b1d6c122e02cba9b02458120b5fb0c87b746c41e0207cf642cf"),
            File("1_Pooling/config.json", 190, "d1caf60c96f5fba2157c0c26b76d80818fad6cf0b8eb5e73ec372ff9818eba5c"),
            File("model.safetensors", 133_466_304, "3c9f31665447c8911517620762200d2245a2518d6e7208acc78cd9db317e21ad"),
        ]
    )

    /// The files both Qwen3.5 sizes share at their pinned revisions.
    private static let qwenShared = [
        File("chat_template.jinja", 7756, "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
        File("preprocessor_config.json", 390, "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"),
        File("processor_config.json", 1300, "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b"),
        File("tokenizer.json", 19_989_343, "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
        File("tokenizer_config.json", 1139, "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
        File("video_preprocessor_config.json", 385, "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13"),
        File("vocab.json", 6_722_759, "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003"),
    ]

    fileprivate static let small = qwenShared + [
        File("model.safetensors.index.json", 101_944, "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a"),
        File("model.safetensors", 3_034_300_695, "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"),
        File("config.json", 3366, "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa"),
    ]

    fileprivate static let medium = qwenShared + [
        File("model.safetensors.index.json", 123_592, "dd023913fb87cfdae27fb11dcf695117c925833796ccac3c64117d6652d8ff1e"),
        File("model-00001-of-00002.safetensors", 5_349_771_222, "a68b87558c6ef43f74c2bd63ce7e9092ceddc3101f3def0030774bae5f42aadd"),
        File("model-00002-of-00002.safetensors", 600_449_850, "b0a770bf8469c7f3f18756a0e0283f1c1174344a83e059a4e483f6af4907352d"),
        File("config.json", 3331, "a96942cb6a8a1d3f1d17514d81a1925d04362a6a3233b389d13012211baaa9f8"),
    ]
}

private extension ModelFiles.File {
    init(_ path: String, _ bytes: Int64, _ sha256: String) {
        self.init(path: path, bytes: bytes, sha256: sha256)
    }
}

public extension ModelChoice {
    /// This model's pinned files.
    var files: ModelFiles {
        ModelFiles(
            repository: repository, revision: revision, folderName: folderName,
            files: self == .medium ? ModelFiles.medium : ModelFiles.small
        )
    }

    /// The tune-up's verdict (ADR-0030): the 9B steps down to the 4B when it writes fewer than 8 tokens a second here.
    func tuned(_ metrics: ModelMetrics) -> ModelChoice {
        guard self == .medium, let tokens = metrics.generationTokens, let seconds = metrics.generateSeconds, seconds > 0 else {
            return self
        }
        return Double(tokens) / seconds < 8 ? .small : self
    }

    /// The model recorded by the tune-up in `folder` (Aegis's own), if any.
    static func chosen(in folder: URL) -> ModelChoice? {
        let saved = try? String(contentsOf: folder.appendingPathComponent("model-choice"), encoding: .utf8)
        return [ModelChoice.small, .medium].first { $0.name == saved?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Records the tune-up's choice in `folder`; AegisCore and ModelService follow it from their next start.
    func choose(in folder: URL) throws {
        try name.write(to: folder.appendingPathComponent("model-choice"), atomically: true, encoding: .utf8)
    }

    /// Aegis's own folder (`~/Library/Application Support/Aegis` on the Mac).
    static var aegisFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Aegis")
    }
}
