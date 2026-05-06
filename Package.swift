// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// audd-swift — official Swift SDK for the AudD music recognition API.
//
// Compile target: Swift 5.9+
// Deployment targets:
//   - iOS 15+
//   - macOS 12+
//   - watchOS 8+
//   - tvOS 15+
//   - visionOS 1+
//   - Linux (no platform marker; declared by Swift Package Manager via the linux runtime)
import PackageDescription

let package = Package(
    name: "audd-swift",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .watchOS(.v8),
        .tvOS(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "AudD",
            targets: ["AudD"]
        ),
        .executable(name: "RecognizeUrl", targets: ["RecognizeUrl"]),
        .executable(name: "RecognizeFile", targets: ["RecognizeFile"]),
        .executable(name: "RecognizeEnterprise", targets: ["RecognizeEnterprise"]),
        .executable(name: "StreamsSetup", targets: ["StreamsSetup"]),
        .executable(name: "StreamsLongpoll", targets: ["StreamsLongpoll"]),
        .executable(name: "CustomCatalogAdd", targets: ["CustomCatalogAdd"]),
        .executable(name: "TokenlessLongpoll", targets: ["TokenlessLongpoll"]),
        .executable(name: "ScanAndRename", targets: ["ScanAndRename"]),
        .executable(name: "StreamToCsv", targets: ["StreamToCsv"]),
    ],
    dependencies: [
        // DocC plugin — only used by `swift package generate-documentation`,
        // doesn't affect library consumers (build dependency, not a runtime one).
        // Pinned to 1.x so a future 2.0 doesn't silently break local docs builds.
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "AudD",
            path: "Sources/AudD",
            swiftSettings: [
                // Opt-in Swift 6 strict-concurrency checking. The flag enables
                // Sendable / actor-isolation diagnostics in the `AudD` target
                // so the SDK is data-race-free across actor boundaries and
                // ready for Swift 6 mode without code changes by users. The
                // SDK additionally builds clean under the more aggressive
                // `-strict-concurrency=complete`.
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // Each example is a standalone runnable target. Build any with
        // `swift build --target <name>`; run with `swift run <name>`.
        .executableTarget(
            name: "RecognizeUrl",
            dependencies: ["AudD"],
            path: "Examples/RecognizeUrl"
        ),
        .executableTarget(
            name: "RecognizeFile",
            dependencies: ["AudD"],
            path: "Examples/RecognizeFile"
        ),
        .executableTarget(
            name: "RecognizeEnterprise",
            dependencies: ["AudD"],
            path: "Examples/RecognizeEnterprise"
        ),
        .executableTarget(
            name: "StreamsSetup",
            dependencies: ["AudD"],
            path: "Examples/StreamsSetup"
        ),
        .executableTarget(
            name: "StreamsLongpoll",
            dependencies: ["AudD"],
            path: "Examples/StreamsLongpoll"
        ),
        .executableTarget(
            name: "CustomCatalogAdd",
            dependencies: ["AudD"],
            path: "Examples/CustomCatalogAdd"
        ),
        .executableTarget(
            name: "TokenlessLongpoll",
            dependencies: ["AudD"],
            path: "Examples/TokenlessLongpoll"
        ),
        .executableTarget(
            name: "ScanAndRename",
            dependencies: ["AudD"],
            path: "Examples/ScanAndRename",
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "StreamToCsv",
            dependencies: ["AudD"],
            path: "Examples/StreamToCsv",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "AudDTests",
            dependencies: ["AudD"],
            path: "Tests/AudDTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
