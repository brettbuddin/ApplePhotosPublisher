// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LRPhotosImporter",
    platforms: [
        .macOS(.v12) // Required for async/await PhotoKit APIs
    ],
    products: [
        .executable(name: "lrphotosimporter", targets: ["lrphotosimporter"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.58.0")
    ],
    targets: [
        .executableTarget(
            name: "lrphotosimporter",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "ImporterTests",
            dependencies: ["lrphotosimporter"],
            path: "Tests/ImporterTests"
        )
    ]
)
