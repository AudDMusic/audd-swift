// Tokenless longpoll consumer for browser/widget/extension use cases.
//
// Carries no api_token. The category alone authorizes the subscription. The
// user/server who derived the category is responsible for ensuring a callback
// URL is set on their account (we can't preflight that without a token).
//
// Hardening (spec §6.7):
// * HTTP non-2xx → emits AudDError.serverError on the LongpollPoll's `errors` stream
// * JSON decode failure → emits AudDError.serializationError on `errors`
// * READ-class retries on 5xx + connection errors (spec parity)
// * Configurable maxAttempts / backoffFactor
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

public final class LongpollConsumer: @unchecked Sendable {
    /// Default longpoll endpoint. Computed (not stored) to sidestep the Swift
    /// 5.10 strict-concurrency warning on a `static let` of a non-`Sendable`
    /// Foundation type — `URL` is a value type and safe to share, but the
    /// compiler doesn't know that yet on Linux.
    public static var longpollURL: URL { URL(string: "https://api.audd.io/longpoll/")! }

    private let category: String
    private let session: URLSession
    private let ownsSession: Bool
    private let policy: RetryPolicy
    private let endpoint: URL

    public init(
        category: String,
        urlSession: URLSession? = nil,
        maxRetries: Int = 3,
        backoffFactor: Double = 0.5,
        endpoint: URL = LongpollConsumer.longpollURL
    ) {
        self.category = category
        self.endpoint = endpoint
        if let urlSession {
            self.session = urlSession
            self.ownsSession = false
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = HTTPRequestTimeouts.longpoll.connect
            config.timeoutIntervalForResource = HTTPRequestTimeouts.longpoll.resource
            self.session = URLSession(configuration: config)
            self.ownsSession = true
        }
        self.policy = RetryPolicy(retryClass: .read, maxAttempts: maxRetries, backoffFactor: backoffFactor)
    }

    /// Start a long-poll subscription. Returns a ``LongpollPoll`` whose
    /// `matches` / `notifications` / `errors` AsyncStreams are filled by a
    /// background task. Call `await poll.close()` to tear down.
    public func iterate(options: LongpollOptions = LongpollOptions()) -> LongpollPoll {
        let session = self.session
        let endpoint = self.endpoint
        let policy = self.policy
        let fetch: @Sendable (_ params: [String: String]) async throws -> HTTPResponseEnvelope = { params in
            return try await withRetry(policy: policy) {
                let env = try await fetchLongpoll(session: session, endpoint: endpoint, params: params)
                if shouldRetryStatus(env.httpStatus, retryClass: policy.retryClass) {
                    return RetryableResponse<HTTPResponseEnvelope>.retryable(status: env.httpStatus, rawText: env.rawText, requestID: env.requestID)
                }
                return RetryableResponse<HTTPResponseEnvelope>.success(env, status: env.httpStatus, rawText: env.rawText, requestID: env.requestID)
            }
        }
        return LongpollPoll(category: category, options: options, fetch: fetch)
    }

    public func close() {
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
    }

    deinit {
        close()
    }
}

private func fetchLongpoll(session: URLSession, endpoint: URL, params: [String: String]) async throws -> HTTPResponseEnvelope {
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
    let url = components.url ?? endpoint
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(UserAgent.string(), forHTTPHeaderField: "User-Agent")

    return try await withCheckedThrowingContinuation { continuation in
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            guard let data, let response else {
                continuation.resume(throwing: URLError(.badServerResponse))
                return
            }
            continuation.resume(returning: HTTPResponseEnvelope.parse(data: data, response: response))
        }
        task.resume()
    }
}
