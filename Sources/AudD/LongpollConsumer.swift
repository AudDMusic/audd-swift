// Tokenless longpoll consumer for browser/widget/extension use cases.
//
// Carries no api_token. The category alone authorizes the subscription. The
// user/server who derived the category is responsible for ensuring a callback
// URL is set on their account (we can't preflight that without a token).
//
// Hardening (spec §6.7):
// * HTTP non-2xx → throws AudDError.serverError (not silent loop forever)
// * JSON decode failure → throws AudDError.serializationError
// * READ-class retries on 5xx + connection errors (spec parity)
// * Configurable maxAttempts / backoffFactor
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

    /// Iterate longpoll responses. Each yield is the parsed JSON object.
    public func iterate(sinceTime: Int? = nil, timeout: Int = 50) -> AsyncThrowingStream<[String: AnyCodable], Error> {
        let category = self.category
        let session = self.session
        let policy = self.policy
        let endpoint = self.endpoint

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var cursor = sinceTime
                    while !Task.isCancelled {
                        var paramsBuilder: [String: String] = ["category": category, "timeout": String(timeout)]
                        if let cursor { paramsBuilder["since_time"] = String(cursor) }
                        // Capture an immutable snapshot for the @Sendable closure.
                        let params = paramsBuilder

                        let envelope = try await withRetry(policy: policy) {
                            let env = try await fetchLongpoll(session: session, endpoint: endpoint, params: params)
                            if shouldRetryStatus(env.httpStatus, retryClass: policy.retryClass) {
                                return RetryableResponse<HTTPResponseEnvelope>.retryable(status: env.httpStatus, rawText: env.rawText, requestID: env.requestID)
                            }
                            return RetryableResponse<HTTPResponseEnvelope>.success(env, status: env.httpStatus, rawText: env.rawText, requestID: env.requestID)
                        }
                        // Non-2xx (terminal — we're past retry exhaustion if we got here non-success)
                        if envelope.httpStatus >= AudDErrorCodes.httpClientErrorFloor {
                            throw AudDError.serverError(
                                httpStatus: envelope.httpStatus,
                                message: "Longpoll endpoint returned HTTP \(envelope.httpStatus)",
                                requestID: envelope.requestID,
                                rawText: envelope.rawText
                            )
                        }
                        guard let body = envelope.jsonBody else {
                            throw AudDError.serializationError(
                                message: "Longpoll response was not a JSON object",
                                rawText: envelope.rawText
                            )
                        }
                        var converted: [String: AnyCodable] = [:]
                        for (k, v) in body { converted[k] = AnyCodable(v) }
                        continuation.yield(converted)
                        if let ts = body["timestamp"] as? Int {
                            cursor = ts
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
