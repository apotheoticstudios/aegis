// swift-tools-version: 6.0
// AegisKit: the Linux-testable core. No Apple-only frameworks (AppKit, SwiftUI,
// EventKit, HomeKit, Metal, MLX...) may be imported here. See ADR-0004.
import PackageDescription

let package = Package(
    name: "AegisKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AegisKit", targets: ["AegisKit"]),
        .library(name: "AegisStorage", targets: ["AegisStorage"]),
    ],
    dependencies: [
        // AegisStorage only; the AegisKit target stays free of third-party code (ADR-0012).
        .package(
            url: "https://github.com/groue/GRDB.swift", // privacy-guard: allow-network one-time package download, ADR-0012
            exact: "7.11.1"
        ),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(
            name: "AegisKit",
            dependencies: ["CSQLite"],
            resources: [
                .copy("Pipeline/prompt.md"),
                .copy("Ask/ask-prompt.md"),
                .copy("Prep/prep-prompt.md"),
                .copy("Drafts/draft-prompt.md"),
                .copy("Chat/chat-prompt.md"),
                .copy("World/world-actions.md"),
            ]
        ),
        .testTarget(name: "AegisKitTests", dependencies: ["AegisKit", "CSQLite"]),
        .target(name: "AegisStorage", dependencies: ["AegisKit", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "AegisStorageTests", dependencies: ["AegisStorage"]),
    ]
)
