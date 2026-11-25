// Tokenless longpoll consumer for browser/widget/extension use cases.
//
// Carries no api_token. The category alone authorizes the subscription. The
// user/server who derived the category is responsible for ensuring a callback
// URL is set on their account (we can't preflight that without a token).
//
// Behaviour (shared with Streams.longpoll, see LongpollPoll):
// * events are delivered in order; unparseable events are skipped
// * since_time follows the newest timestamp the server sent
// * a response with nothing new is followed by a 1 s → 30 s backoff
// * an `{"error": ...}` body or HTTP 4xx ends the subscription on `errors`
// * READ-class retries on 5xx + connection errors, `maxRetries` attempts
//
// `iterate(...)` returns a ``LongpollPoll`` — same shape as
// ``Streams/longpoll(category:options:)``: typed `matches` / `notifications` /
// `errors` AsyncStreams. Call `await poll.close()` to tear down.
//
// `@preconcurrency import Foundation` is required because Foundation's `URL`
// and `URLSession` aren't formally `Sendable` on Linux through Swift 5.10 —
// they are in practice (URL is a value type; URLSession is documented as
// thread-safe), but the type system doesn't know yet. The `@preconcurrency`
// attribute downgrades these crossings to warnings outside Swift 6 mode.
@preconcurrency import Foundation

#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

/// Subscribes to longpoll events with only a category, no api_token. See
/// ``LongpollPoll`` for how responses are handled.
public final class LongpollConsumer: @unchecked Sendable {
    /// Default longpoll endpoint. Computed (not stored) to sidestep the Swift
    /// 5.10 strict-concurrency warning on a `static let` of a non-`Sendable`
    /// Foundation type — `URL` is a value type and safe to share, but the
    /// compiler doesn't know that yet on Linux.
    public static var longpollURL: URL { URL(string: "https://api.audd.io/longpoll/")! }

    private let category: String
    private let session: ManagedSession
    private let policy: RetryPolicy
    private let endpoint: URL

    /// - Parameters:
    ///   - category: the 9-char longpoll category.
    ///   - urlSession: inject your own session (proxy, pinning). Each request
    ///     sets its own `timeoutInterval` from the poll's `timeout`.
    ///   - maxRetries: total attempts per request on network failures and
    ///     HTTP 408 / 429 / 5xx before the subscription ends on `errors`.
    ///   - backoffFactor: initial pause between those attempts, in seconds.
    public init(
        category: String,
        urlSession: URLSession? = nil,
        maxRetries: Int = 3,
        backoffFactor: Double = 0.5,
        endpoint: URL = LongpollConsumer.longpollURL
    ) {
        self.category = category
        self.endpoint = endpoint
        self.session = ManagedSession(urlSession: urlSession, timeouts: .longpoll)
        self.policy = RetryPolicy(retryClass: .read, maxAttempts: maxRetries, backoffFactor: backoffFactor)
    }

    /// Start a long-poll subscription. Returns a ``LongpollPoll`` whose
    /// `matches` / `notifications` / `errors` AsyncStreams are filled by a
    /// background task. Call `await poll.close()` to tear down.
    public func iterate(options: LongpollOptions = LongpollOptions()) -> LongpollPoll {
        let session = self.session
        let endpoint = self.endpoint
        let policy = self.policy
        let fetch: LongpollFetch = { params, requestTimeout in
            return try await withRetry(policy: policy) {
                let request = makeGETRequest(url: endpoint, params: params, timeout: requestTimeout)
                let (data, response) = try await performDataTask(session: session, request: request)
                let env = HTTPResponseEnvelope.parse(data: data, response: response)
                if shouldRetryStatus(env.httpStatus, retryClass: policy.retryClass) {
                    return RetryableResponse<HTTPResponseEnvelope>.retryable(status: env.httpStatus, rawText: env.rawText, requestID: env.requestID)
                }
                return RetryableResponse<HTTPResponseEnvelope>.success(env, status: env.httpStatus, rawText: env.rawText, requestID: env.requestID)
            }
        }
        return LongpollPoll(category: category, options: options, fetch: fetch)
    }

    /// Release the consumer's `URLSession`. When the consumer created the
    /// session, a request still waiting on the server is cancelled and the
    /// polls started from this consumer end; with an injected `urlSession`,
    /// stop each poll with ``LongpollPoll/close()``. Idempotent.
    public func close() {
        session.close(cancelRunning: true)
    }
}
