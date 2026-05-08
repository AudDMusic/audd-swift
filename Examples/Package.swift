// swift-tools-version: 5.9
//
// Examples for audd-swift. This is a sibling SwiftPM package — separate from
// the SDK proper at ../Package.swift — so that the public package surface
// stays minimal (only the AudD library product) and downstream consumers
// don't pull in CLI executable targets they'll never use.
//
// Run any example from this directory:
//
//     cd Examples
//     swift run RecognizeUrl
//     swift run StreamToCsv ...
//
// CI builds this package on macOS and Linux to verify examples stay buildable.
// The main package is platform-portable (iOS / watchOS / tvOS / visionOS too);
// this examples package is intentionally narrower.
import PackageDescription

let package = Package(
    name: "audd-swift-examples",
    platforms: [
        .macOS(.v12),
    ],
    dependencies: [
        .package(name: "audd-swift", path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "RecognizeUrl",
            dependencies: [.product(name: "AudD", package: "audd-swift")],
            path: "RecognizeUrl"
        ),
        .executableTarget(
            name: "RecognizeFile",
            dependencies: [.product(name: "AudD", package: "audd-swift")],
            path: "RecognizeFile"
        ),
        .executableTarget(
            name: "RecognizeEnterprise",
            dependencies: [.product(name: "AudD", package: "audd-swift")],
            path: "RecognizeEnterprise"
        ),
        .executableTarget(
            name: "StreamsSetup",
            dependencies: [.product(name: "AudD", package: "audd-swift")],
            path: "StreamsSetup"
        ),
        .executableTarget(
            name: "StreamsLongpoll",
            dependencies: [.product(name: "AudD", package: "audd-swift")],
            path: "StreamsLongpoll"
        ),
        .executableTarget(
            name: "CustomCatalogAdd",
            dependencies: [.product(name: "AudD", package: "audd-swift")],
            path: "CustomCatalogAdd"
        ),
        .executableTarget(
            name: "TokenlessLongpoll",
            dependencies: [.product(name: "AudD", package: "audd-swift")],
            path: "TokenlessLongpoll"
        ),
        .executableTarget(
            name: "ScanAndRename",
            dependencies: [.product(name: "AudD", package: "audd-swift")],
            path: "ScanAndRename",
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "StreamToCsv",
            dependencies: [.product(name: "AudD", package: "audd-swift")],
            path: "StreamToCsv",
            exclude: ["README.md"]
        ),
    ]
)
