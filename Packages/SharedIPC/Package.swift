// swift-tools-version: 6.0
// SharedIPC: the Mac-only XPC glue that carries AegisKit's contracts between Aegis.app, AegisCore and
// ModelService (ADR-0013). AegisKit stays Linux-testable; everything NSXPC lives here.
import PackageDescription

let package = Package(
    name: "SharedIPC",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SharedIPC", targets: ["SharedIPC"]),
    ],
    dependencies: [
        .package(path: "../AegisKit"),
    ],
    targets: [
        .target(name: "SharedIPC", dependencies: [.product(name: "AegisKit", package: "AegisKit")]),
        .testTarget(name: "SharedIPCTests", dependencies: ["SharedIPC"]),
    ]
)
