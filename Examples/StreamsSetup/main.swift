// End-to-end stream setup: set callback URL, add a stream, list subscribed
// streams to verify.
//
// Usage: AUDD_API_TOKEN=... swift run StreamsSetup
//
// Replace the placeholders below with your real callback URL and stream URL
// before running.
import Foundation
import AudD

#if os(macOS) || os(Linux)
@main
struct StreamsSetupExample {
    static func main() async {
        do {
            guard let token = ProcessInfo.processInfo.environment["AUDD_API_TOKEN"] else {
                print("AUDD_API_TOKEN must be set")
                exit(1)
            }
            let audd = try AudD(apiToken: token)
            defer {
                Task { await audd.close() }
            }

            // Configure a callback URL on your account. Use https://audd.tech/empty/
            // if you only want longpolling and don't need a real receiver.
            let streams = await audd.streams
            try await streams.setCallbackURL("https://your-server.example.com/audd-callback")

            // Subscribe a stream URL for live recognition. radioID is your
            // caller-side identifier; it'll show up in callback payloads.
            try await streams.add(
                url: "https://npr-ice.streamguys1.com/live.mp3",
                radioID: 1
            )

            // List to verify.
            let list = try await streams.list()
            for s in list {
                print("radio \(s.radioID)  running=\(s.streamRunning)  category=\(s.longpollCategory ?? "(none)")")
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
struct StreamsSetup_UnsupportedPlatformStub {
    static func main() {
        print("This CLI example is intended for macOS or Linux.")
    }
}
#endif
