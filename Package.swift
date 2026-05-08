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
