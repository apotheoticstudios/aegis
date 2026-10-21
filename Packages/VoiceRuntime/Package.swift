// swift-tools-version: 6.2
import PackageDescription

/// Native on-device speech, bundled with Aegis; ADR-0018, #221.
let package = Package(
    name: "VoiceRuntime",
    platforms: [.macOS(.v15)],
    products: [.library(name: "VoiceRuntime", targets: ["VoiceRuntime"])],
    dependencies: [
        .package(
            url: "https://github.com/Jud/kokoro-coreml.git", // privacy-guard: allow-network pinned build-time dependency, ADR-0018
            exact: "0.11.2"
        ),
    ],
    targets: [
        .target(name: "VoiceRuntime", dependencies: [.product(name: "KokoroCoreML", package: "kokoro-coreml")]),
        .testTarget(name: "VoiceRuntimeTests", dependencies: ["VoiceRuntime"]),
    ]
)
