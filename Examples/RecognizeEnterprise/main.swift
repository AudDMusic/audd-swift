// Recognize a long-form audio file (>25 s, up to ~120 minutes) on the
// enterprise endpoint with chunk-based timecode results.
//
// Usage: AUDD_API_TOKEN=... swift run RecognizeEnterprise <path-to-audio-file>
//
// The enterprise endpoint requires its own subscription — see
// https://dashboard.audd.io for access.
import Foundation
import AudD

@main
struct RecognizeEnterpriseExample {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            print("usage: swift run RecognizeEnterprise <path-to-audio-file>")
            exit(1)
        }
        let fileURL = URL(fileURLWithPath: CommandLine.arguments[1])

        do {
            // Enterprise calls require an account-bound token — fall back to
            // the public test token only as a last resort, since enterprise
            // access is gated.
            let audd = try AudD(
                apiToken: ProcessInfo.processInfo.environment["AUDD_API_TOKEN"] ?? "test"
            )
            defer {
                Task { await audd.close() }
            }
            // limit=1 in dev/testing to bound cost (1 chunk ≈ 18 s of audio).
            let matches = try await audd.recognizeEnterprise(
                .file(fileURL),
                returnMetadata: ["apple_music", "spotify"],
                limit: 1
            )
            if matches.isEmpty {
                print("No matches")
                return
            }
            for (i, m) in matches.enumerated() {
                print("[\(i)] \(m.artist ?? "?") — \(m.title ?? "?") (score \(m.score), timecode \(m.timecode))")
                if let isrc = m.isrc { print("    ISRC: \(isrc)") }
                if let upc = m.upc { print("    UPC: \(upc)") }
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
