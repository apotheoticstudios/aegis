// swift-tools-version: 6.2
// ModelRuntime: ModelService's MLX model (Stage 1 step 2.12, #118; ADR-0009, ADR-0011, ADR-0014).
// macOS-only and built with xcodebuild (MLX compiles Metal shaders), by `make app` on the owner's Mac;
// CI builds the placeholder ModelService in project.yml instead, so it never compiles MLX.
// The folder is not called mlx-…: a package's identity is its folder name (ADR-0011).
import PackageDescription

let package = Package(
    name: "ModelRuntime",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ModelRuntime", targets: ["ModelRuntime"]),
        .executable(name: "ModelService", targets: ["ModelService"]),
    ],
    dependencies: [
        .package(path: "../SharedIPC"),
        .package(path: "../AegisKit"),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm", // privacy-guard: allow-network one-time package download, pinned in ADR-0011
            exact: "3.32.3"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers", // privacy-guard: allow-network one-time package download, pinned in ADR-0011
            exact: "1.3.4"
        ),
    ],
    targets: [
        .target(
            name: "ModelRuntime",
            dependencies: [
                .product(name: "AegisKit", package: "AegisKit"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "accuracy-run",
            dependencies: [
                "ModelRuntime", .product(name: "AegisKit", package: "AegisKit"),
                .product(name: "AegisStorage", package: "AegisKit"),
            ]
        ),
        // Development check with synthetic events only; not part of Aegis.app.
        .executableTarget(
            name: "model-smoke",
            dependencies: ["ModelRuntime", .product(name: "AegisKit", package: "AegisKit")]
        ),
        // ADR-0032: the model's search plans for synthetic questions, scored; not part of Aegis.app.
        .executableTarget(
            name: "search-eval",
            dependencies: ["ModelRuntime", .product(name: "AegisKit", package: "AegisKit")]
        ),
        // #52: conversation turns from the cached prefix, synthetic only; not part of Aegis.app.
        .executableTarget(
            name: "chat-smoke",
            dependencies: ["ModelRuntime", .product(name: "AegisKit", package: "AegisKit")]
        ),
        // Stage 1 step 3.2: the synthetic held-out day through the real engine and model; not part of Aegis.app.
        .executableTarget(
            name: "heldout-run",
            dependencies: [
                "ModelRuntime",
                .product(name: "AegisKit", package: "AegisKit"),
                .product(name: "AegisStorage", package: "AegisKit"),
            ]
        ),
        .executableTarget(
            name: "ModelService",
            dependencies: [
                "ModelRuntime",
                .product(name: "SharedIPC", package: "SharedIPC"),
                .product(name: "AegisKit", package: "AegisKit"),
            ]
        ),
    ]
)
