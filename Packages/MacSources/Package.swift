// swift-tools-version: 6.0
// MacSources: AegisCore's readers for Calendar, Reminders and Contacts (Stage 1 step 2.11, #107).
// macOS-only (EventKit, Contacts). The mapping to AegisKit's contracts is tested with synthetic values;
// nothing here is tested against the owner's real stores.
import PackageDescription

let package = Package(
    name: "MacSources",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacSources", targets: ["MacSources"]),
    ],
    dependencies: [
        .package(path: "../AegisKit"),
    ],
    targets: [
        .target(name: "MacSources", dependencies: [.product(name: "AegisKit", package: "AegisKit")]),
        .testTarget(name: "MacSourcesTests", dependencies: ["MacSources"]),
    ]
)
