// swift-tools-version: 6.2
import PackageDescription

/// Pinned, checksum-verified macOS libraries; build-time downloads only (ADR-0019).
let package = Package(
    name: "WakeRuntime",
    platforms: [.macOS(.v15)],
    products: [.library(name: "WakeRuntime", targets: ["WakeRuntime"])],
    targets: [
        .binaryTarget(
            name: "SherpaOnnxMacOS",
            // privacy-guard: allow-network pinned public build dependency, ADR-0019
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-macos-static.xcframework.zip", // privacy-guard: allow-network pinned public build dependency, ADR-0019
            checksum: "93f7a064abe99e0d6185a88c5b36ce18c4bff35cd0d5e4e81f81151de8e3e7e5"
        ),
        .binaryTarget(
            name: "OnnxruntimeMacOS",
            // privacy-guard: allow-network pinned public build dependency, ADR-0019
            url: "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.1/onnxruntime-macos-static-xcframework-1.28.1.xcframework.zip", // privacy-guard: allow-network pinned public build dependency, ADR-0019
            checksum: "38c9a1e8bcf2497ff5eb721195743e4b4367ade3cd1eb9869c0cfd1bd367c36b"
        ),
        .target(
            name: "WakeRuntime", dependencies: ["SherpaOnnxMacOS", "OnnxruntimeMacOS"],
            linkerSettings: [.linkedLibrary("c++"), .linkedFramework("CoreML"), .linkedFramework("Foundation")]
        ),
        .testTarget(name: "WakeRuntimeTests", dependencies: ["WakeRuntime"]),
    ]
)
