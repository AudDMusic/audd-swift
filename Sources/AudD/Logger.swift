// Lightweight logging hook used for the C3 deprecation pass-through (code 51).
// On Apple platforms we use `os.Logger`; on Linux we fall back to stderr with a
// `[deprecation]` tag so the message is still observable.
import Foundation

#if canImport(os)
import os
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum AudDLog {
    static func deprecation(_ message: String) {
        #if canImport(os)
        if #available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *) {
            let logger = Logger(subsystem: "io.audd.audd-swift", category: "deprecation")
            logger.warning("\(message, privacy: .public)")
            return
        }
        #endif
        let line = "[deprecation] audd-swift: \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
