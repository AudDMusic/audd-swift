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
        defer { consumer.close() }

        do {
            for try await payload in consumer.iterate(timeout: 30) {
                print("Event: \(payload)")
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
