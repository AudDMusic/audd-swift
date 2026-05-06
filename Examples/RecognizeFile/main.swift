// Recognize a song from a local audio file.
//
// Usage: swift run RecognizeFile <path-to-audio-file>
//
// The SDK reads the bytes once and reuses them across retries, so the file
// only needs to be readable on the first attempt.
import Foundation
import AudD

#if os(macOS) || os(Linux)
@main
struct RecognizeFileExample {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            print("usage: swift run RecognizeFile <path-to-audio-file>")
            exit(1)
        }
        let path = CommandLine.arguments[1]
        let fileURL = URL(fileURLWithPath: path)

        do {
            let audd = try AudD(
                apiToken: ProcessInfo.processInfo.environment["AUDD_API_TOKEN"] ?? "test"
            )
            defer {
                Task { await audd.close() }
            }
            let result = try await audd.recognize(.file(fileURL))
            if let result {
                print("Match: \(result.artist ?? "?") — \(result.title ?? "?") (timecode \(result.timecode))")
                if let link = result.songLink {
                    print("Song link: \(link)")
                }
            } else {
                print("No match")
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
#else
// CLI examples run on macOS and Linux. iOS/tvOS/watchOS/visionOS get a stub
// so the package still builds cleanly on every declared platform.
@main
struct RecognizeFile_UnsupportedPlatformStub {
    static func main() {
        print("This CLI example is intended for macOS or Linux.")
    }
}
#endif
