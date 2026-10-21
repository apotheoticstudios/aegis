// swift-tools-version: 6.0
// Background agent + Full Disk Access check (Stage 0, issue #11). A Mac-only spike, not part of the app.
// `build.sh` assembles the two executables into a test .app with an SMAppService launch agent.
import PackageDescription

let package = Package(
    name: "AgentFDATest",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "fda-test-app"),
        .executableTarget(name: "fda-agent"),
    ]
)
