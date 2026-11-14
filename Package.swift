// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UpdateKit",
    // British English is the source language; each target's String Catalog holds the
    // English and its translations, and the apps using the package pick them up.
    defaultLocalization: "en-GB",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "UpdateKit", targets: ["UpdateKit"]),
        .library(name: "UpdateKitUI", targets: ["UpdateKitUI"]),
        // For an app's long-lived helpers (MCP servers): become the updated build in
        // place, keeping the process and its client's connection. No AppKit.
        .library(name: "UpdateKitHandOver", targets: ["UpdateKitHandOver"]),
    ],
    targets: [
        .target(name: "UpdateKit", resources: [.process("Resources")]),
        .target(name: "UpdateKitUI", dependencies: ["UpdateKit"], resources: [.process("Resources")]),
        .target(name: "UpdateKitHandOver"),
        // A stand-in helper the hand-over tests run, replace on disk, and talk to.
        .executableTarget(name: "HandOverDemo", dependencies: ["UpdateKitHandOver"]),
        .testTarget(name: "UpdateKitTests", dependencies: ["UpdateKit", "UpdateKitUI"]),
        .testTarget(name: "UpdateKitHandOverTests", dependencies: ["UpdateKitHandOver", "HandOverDemo"]),
    ]
)
