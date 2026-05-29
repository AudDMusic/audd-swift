// Hello-world recognize-by-URL example. Uses the public `test` token.
//
// Run via: swift run RecognizeUrl
import Foundation
import AudD

@main
struct RecognizeUrlExample {
    static func main() async {
        // Picks up AUDD_API_TOKEN from the environment automatically; falls back
        // to the public test token when no env-var is set.
        do {
            let audd = try AudD(
                apiToken: ProcessInfo.processInfo.environment["AUDD_API_TOKEN"] ?? "test"
            )
            defer {
                Task { await audd.close() }
            }
            let result = try await audd.recognize("https://audd.tech/example.mp3")
            if let result {
                print("Match: \(result.artist ?? "?") — \(result.title ?? "?") (timecode \(result.timecode ?? "?"))")
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
