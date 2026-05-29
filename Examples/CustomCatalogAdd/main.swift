// Add a song to your custom (private) fingerprint catalog.
//
// **This is NOT music recognition** — it stores a fingerprint so AudD's
// recognition can later identify _your own_ tracks for _your account_. For
// recognition, use the recognize() / recognizeEnterprise() examples.
//
// Custom catalog access is gated; contact api@audd.io to enable on your account.
//
// Usage: AUDD_API_TOKEN=... swift run CustomCatalogAdd <audio_id> <path-to-audio-file>
//
// audioID is your caller-side integer identifier for the song. Calling this
// again with the same audioID re-fingerprints that slot.
import Foundation
import AudD

@main
struct CustomCatalogAddExample {
    static func main() async {
        guard CommandLine.arguments.count == 3,
              let audioID = Int(CommandLine.arguments[1])
        else {
            print("usage: swift run CustomCatalogAdd <audio_id> <path-to-audio-file>")
            exit(1)
        }
        let fileURL = URL(fileURLWithPath: CommandLine.arguments[2])

        do {
            guard let token = ProcessInfo.processInfo.environment["AUDD_API_TOKEN"] else {
                print("AUDD_API_TOKEN must be set")
                exit(1)
            }
            let audd = try AudD(apiToken: token)
            defer {
                Task { await audd.close() }
            }
            let catalog = await audd.customCatalog
            try await catalog.add(audioID: audioID, source: .file(fileURL))
            print("Added audioID \(audioID) from \(fileURL.path)")
        } catch let AudDError.api(detail) where detail.kind == .customCatalogAccess {
            print("Custom catalog access not enabled on this account.")
            print("Contact api@audd.io to request access.")
            print("\(detail.message)")
            exit(2)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
