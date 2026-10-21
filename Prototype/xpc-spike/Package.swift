// swift-tools-version: 6.0
// XPC routing and authentication spike (Stage 1, issue #67). A Mac-only throwaway, not part of the app.
// `build.sh` assembles the executables into a test .app with two SMAppService launch agents:
// a AegisCore stand-in and an on-demand ModelService stand-in reached through its Mach service.
import PackageDescription

let package = Package(
    name: "XPCSpike",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "SpikeShared"),
        .executableTarget(name: "spike-app", dependencies: ["SpikeShared"]),
        .executableTarget(name: "model-agent", dependencies: ["SpikeShared"]),
        .executableTarget(name: "core-agent", dependencies: ["SpikeShared"]),
        .executableTarget(name: "rogue-client", dependencies: ["SpikeShared"]),
    ],
    swiftLanguageModes: [.v5]
)
