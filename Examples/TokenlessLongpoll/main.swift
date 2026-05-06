// Tokenless longpoll consumer — for browser/widget/extension use cases that
// don't carry an api_token. The category alone authorizes the subscription.
//
// The user/server who derived the category is responsible for ensuring a
// callback URL is configured on the AudD account first. The tokenless
// consumer can't preflight that without a token.
//
// Usage: swift run TokenlessLongpoll <category>
import Foundation
import AudD

#if os(macOS) || os(Linux)
@main
struct TokenlessLongpollExample {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            print("usage: swift run TokenlessLongpoll <category>")
            print("(category is the 9-char string from streams.deriveLongpollCategory(...))")
            exit(1)
        }
        let category = CommandLine.arguments[1]

        let consumer = LongpollConsumer(category: category)
        let poll = consumer.iterate(options: LongpollOptions(timeout: 30))

        // Drain matches/notifications/errors concurrently. First terminal
        // event (error or external close) ends the program.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await match in poll.matches {
                    print("match: \(match.song.artist) — \(match.song.title)")
                }
            }
            group.addTask {
                for await notif in poll.notifications {
                    print("notification: \(notif.notificationMessage)")
                }
            }
            group.addTask {
                for await error in poll.errors {
                    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
                    await poll.close()
                }
            }
        }
        consumer.close()
    }
}
#else
// CLI examples run on macOS and Linux. iOS/tvOS/watchOS/visionOS get a stub
// so the package still builds cleanly on every declared platform.
@main
struct TokenlessLongpoll_UnsupportedPlatformStub {
    static func main() {
        print("This CLI example is intended for macOS or Linux.")
    }
}
#endif
