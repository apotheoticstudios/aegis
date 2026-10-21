// swift-tools-version: 6.0
// Empty-shell memory rig (Stage 0, issue #12): the smallest menu-bar app and background agent,
// measured to find the floor of Aegis's 300 MB idle budget. A Mac-only spike, not part of the app.
import PackageDescription

let package = Package(
    name: "IdleRig",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "idle-menubar"),
        .executableTarget(name: "idle-agent"),
    ]
)
