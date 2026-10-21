// swift-tools-version: 6.0
// Accessibility probe (Stage 0, issue #10). A Mac-only spike, not part of the app.
// AXProbeCore holds the pure logic (tested with synthetic trees); ax-probe talks to the real UI.
import PackageDescription

let package = Package(
    name: "AXProbe",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "AXProbeCore"),
        .executableTarget(name: "ax-probe", dependencies: ["AXProbeCore"]),
        .testTarget(name: "AXProbeCoreTests", dependencies: ["AXProbeCore"]),
    ]
)
