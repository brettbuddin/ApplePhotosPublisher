// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LRPhotosImporter",
    platforms: [
        .macOS(.v12) // Required for async/await PhotoKit APIs
    ],
    products: [
        .executable(name: "lrphotosimporter", targets: ["lrphotosimporter"]),
        .executable(name: "lrphotoslauncher", targets: ["lrphotoslauncher"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.58.0")
    ],
    targets: [
        .target(name: "LaunchSupport"),
        .executableTarget(
            name: "lrphotoslauncher",
            dependencies: [
                "LaunchSupport",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "lrphotosimporter",
            dependencies: [
                "LaunchSupport",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Keep metadata available for direct CLI diagnostics as well.
                // Lightroom must launch the packaged .app via Launch Services;
                // embedding this alone does not establish a separate TCC identity.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Sources/lrphotosimporter/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "ImporterTests",
            dependencies: ["lrphotosimporter", "LaunchSupport"],
            path: "Tests/ImporterTests"
        )
    ]
)
