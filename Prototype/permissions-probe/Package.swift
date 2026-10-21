// swift-tools-version: 6.0
// Signed launch and permissions probe (Stage 1, issue #66). A Mac-only throwaway, not part of the app.
// `build.sh` assembles a test .app with an SMAppService launch agent, signed with the owner's
// Apple Development identity, to see which permissions the agent gets from the app.
import PackageDescription

let package = Package(
    name: "PermissionsProbe",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "ProbeShared"),
        .executableTarget(name: "probe-app", dependencies: ["ProbeShared"]),
        .executableTarget(name: "probe-agent", dependencies: ["ProbeShared"]),
    ],
    swiftLanguageModes: [.v5]
)
