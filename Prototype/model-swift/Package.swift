// swift-tools-version: 6.2
// Stage 1 spike 1b (#54): does MLX Swift run Qwen3.5-4B like Python mlx-lm did in Stage 0?
// The folder is not called mlx-swift: a package's identity is its folder name, and that one clashes.
// Throwaway: nothing in Prototype/ ships. Dependencies pinned exactly; licences in ADR-0011.
import PackageDescription

let package = Package(
    name: "MLXSwiftSpike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm", // privacy-guard: allow-network one-time package download, owner OK 2026-10-08 (#54)
            exact: "3.32.3"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers", // privacy-guard: allow-network one-time package download, owner OK 2026-10-08 (#54)
            exact: "1.3.4"
        ),
    ],
    targets: [
        .executableTarget(
            name: "mlx-brief",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5] // a throwaway spike; the app keeps Swift 6 strict concurrency
)
