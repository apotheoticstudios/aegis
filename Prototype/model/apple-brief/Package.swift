// swift-tools-version: 6.0
// apple-brief (Stage 0, issue #18): a brief from Apple's on-device model (Foundation Models), for
// comparison with the MLX models. AppleBriefCore is pure logic and tested; apple-brief calls the model.
import PackageDescription

let package = Package(
    name: "AppleBrief",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "AppleBriefCore"),
        .executableTarget(name: "apple-brief", dependencies: ["AppleBriefCore"]),
        .testTarget(name: "AppleBriefCoreTests", dependencies: ["AppleBriefCore"]),
    ]
)
