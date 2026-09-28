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
    ],
    targets: [
        .target(name: "UpdateKit", resources: [.process("Resources")]),
        .target(name: "UpdateKitUI", dependencies: ["UpdateKit"], resources: [.process("Resources")]),
        .testTarget(name: "UpdateKitTests", dependencies: ["UpdateKit", "UpdateKitUI"]),
    ]
)
