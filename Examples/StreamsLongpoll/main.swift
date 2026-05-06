// Listen for AudD recognition events via longpoll — no public callback URL
// needed, but a callback URL must be configured on the account (use
// https://audd.tech/empty/ if you have nowhere else to send to).
//
// Usage: AUDD_API_TOKEN=... swift run StreamsLongpoll <radio_id>
//
// The first call to longpoll() preflights getCallbackURL once. If your account
// doesn't have one configured, you'll see a typed error with a hint.
// Pass `LongpollOptions(skipCallbackCheck: true)` to bypass.
import Foundation
import AudD

@main
struct StreamsLongpollExample {
    static func main() async {
        guard CommandLine.arguments.count == 2,
              let radioID = Int(CommandLine.arguments[1])
        else {
            print("usage: swift run StreamsLongpoll <radio_id>")
            exit(1)
        }

        do {
            guard let token = ProcessInfo.processInfo.environment["AUDD_API_TOKEN"] else {
                print("AUDD_API_TOKEN must be set")
                exit(1)
            }
            let audd = try AudD(apiToken: token)
            defer {
                Task { await audd.close() }
            }
            let streams = await audd.streams
            let category = streams.deriveLongpollCategory(radioID: radioID)
            print("Longpoll category for radio \(radioID): \(category)")

            let poll = try await streams.longpoll(
                category: category,
                options: LongpollOptions(timeout: 30)
            )

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await m in poll.matches {
                        print("match: \(m.song.artist) — \(m.song.title)")
                        for alt in m.alternatives {
                            print("  alt: \(alt.artist) — \(alt.title)")
                        }
                    }
                }
                group.addTask {
                    for await n in poll.notifications {
                        print("notification: \(n.notificationMessage)")
                    }
                }
                group.addTask {
                    for await error in poll.errors {
                        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
                        await poll.close()
                    }
                }
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
