// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HasteControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HasteKit", targets: ["HasteKit"]),
        .executable(name: "HasteBar", targets: ["HasteBar"]),
        .executable(name: "hastectl", targets: ["hastectl"]),
    ],
    targets: [
        .target(name: "HasteKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "HasteBar", dependencies: ["HasteKit"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "hastectl", dependencies: ["HasteKit"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // NB: Swift Testing macros fail to resolve in Swift 5 mode with the CLT toolchain.
        .testTarget(name: "HasteKitTests", dependencies: ["HasteKit"]),
    ]
)
