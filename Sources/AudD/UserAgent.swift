// User-Agent string sent on every request. Spec §7.6.
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum UserAgent {
    /// Returns e.g. "audd-swift/0.1.0 swift/5.9 (linux)".
    static func string() -> String {
        return "audd-swift/\(AudDVersion.current) swift/\(swiftVersion) (\(osName))"
    }

    private static var swiftVersion: String {
        #if swift(>=6.0)
        return "6.0"
        #elseif swift(>=5.10)
        return "5.10"
        #elseif swift(>=5.9)
        return "5.9"
        #else
        return "5.x"
        #endif
    }

    private static var osName: String {
        #if os(macOS)
        return "macos"
        #elseif os(iOS)
        return "ios"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(visionOS)
        return "visionos"
        #elseif os(Linux)
        return "linux"
        #elseif os(Windows)
        return "windows"
        #else
        return "unknown"
        #endif
    }
}
