// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UpdateKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "UpdateKit", targets: ["UpdateKit"]),
        .library(name: "UpdateKitUI", targets: ["UpdateKitUI"]),
    ],
    targets: [
        .target(name: "UpdateKit"),
        .target(name: "UpdateKitUI", dependencies: ["UpdateKit"]),
        .testTarget(name: "UpdateKitTests", dependencies: ["UpdateKit", "UpdateKitUI"]),
    ]
)
