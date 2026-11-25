// Streams namespace — set/getCallbackUrl, addStream, longpoll with preflight, etc.
//
// `longpoll(category:options:)` returns a `LongpollPoll` whose `matches` /
// `notifications` / `errors` are typed `AsyncStream`s. Iterate `matches` for
// recognitions, `notifications` for stream-lifecycle events, `errors` for the
// terminal failure. Call `await poll.close()` to tear down.
//
// The longpoll endpoint answers HTTP 200 with one of three bodies:
//   {"events": [{"timestamp": ms, "category": "...", "data": {...}}, ...]}
//       each `data` is the body a callback URL receives;
//   {"timeout": "no events before timeout", "timestamp": ms}
//   {"error": "..."}  an invalid request; the same request fails again.
// A body with `result` / `notification` at the top level is read as one
// callback body.
//
// The longpoll preflight (default-on) calls getCallbackUrl once before
// subscribing; when the server returns code 19, we surface a friendlier
// `AudDError.api(.invalidRequest)` with a URL-config hint. Pass
// `LongpollOptions(skipCallbackCheck: true)` to bypass.
//
// `@preconcurrency import` for Foundation/FoundationNetworking — see AudD.swift
// for the rationale (URL/URLSession Sendable gap on Linux/Swift 5.10).
@preconcurrency import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let preflightNoCallbackHint = """
Longpoll won't deliver events because no callback URL is configured for this account. \
Set one first via streams.setCallbackURL(...) — `https://audd.tech/empty/` is fine if \
you only want longpolling and don't need a real receiver. \
To skip this check, pass LongpollOptions(skipCallbackCheck: true).
"""

/// Options for ``Streams/longpoll(category:options:)``. All fields default to
/// safe values; pass an instance only when you need to override one.
public struct LongpollOptions: Sendable {
    /// Resume after this server timestamp (milliseconds), as carried by a
    /// longpoll event or timeout response. `nil` means "start from now".
    public var sinceTime: Int?
    /// Seconds the server holds each request open waiting for events: 1 to
    /// 120, default 50. A value outside that range ends the subscription with
    /// the server's error on `errors`.
    public var timeout: Int
    /// When `false` (default), preflights `getCallbackURL` once before
    /// subscribing — surfaces a friendly error for the silent-failure mode
    /// where no callback URL is configured for the account.
    public var skipCallbackCheck: Bool

    public init(sinceTime: Int? = nil, timeout: Int = 50, skipCallbackCheck: Bool = false) {
        self.sinceTime = sinceTime
        self.timeout = timeout
        self.skipCallbackCheck = skipCallbackCheck
    }
}

public struct Streams: Sendable {
    let http: HTTPClient
    /// Client for longpoll requests: its session allows the server's longest
    /// hold. Never adds the api_token.
    let longpollHTTP: HTTPClient
    let apiBase: URL
    let readPolicy: RetryPolicy
    let mutatingPolicy: RetryPolicy

    init(http: HTTPClient, longpollHTTP: HTTPClient, apiBase: URL, readPolicy: RetryPolicy, mutatingPolicy: RetryPolicy) {
        self.http = http
        self.longpollHTTP = longpollHTTP
        self.apiBase = apiBase
        self.readPolicy = readPolicy
        self.mutatingPolicy = mutatingPolicy
    }

    private func endpoint(_ path: String) -> URL {
        return apiBase.appendingPathComponent(path).appendingPathComponent("/")
    }

    private func post(_ path: String, fields: [String: String], policy: RetryPolicy) async throws -> Any? {
        let envelope = try await runWithRetry(policy: policy) {
            return try await http.postURLEncoded(url: endpoint(path), fields: fields)
        }
        let body = try decodeOrThrow(envelope)
        return body["result"]
    }

    /// Set the callback URL. If `returnMetadata` is provided, it's appended as a
    /// `?return=<csv>` query param on the URL string (raises on conflict — spec).
    ///
    /// - Parameter extraParameters: additional form fields the typed params don't
    ///   cover. Typed params (`url`) win on collision.
    public func setCallbackURL(
        _ url: String,
        returnMetadata: [String]? = nil,
        extraParameters: [String: String]? = nil
    ) async throws {
        let merged = try addReturnToURL(url, returnMetadata: returnMetadata)
        var fields = extraParameters ?? [:]
        fields["url"] = merged
        _ = try await post("setCallbackUrl", fields: fields, policy: mutatingPolicy)
    }

    /// Return the configured callback URL (or throw if none configured — code 19).
    public func getCallbackURL() async throws -> String {
        let result = try await post("getCallbackUrl", fields: [:], policy: readPolicy)
        if let s = result as? String { return s }
        throw AudDError.serializationError(message: "Expected callback URL string, got \(String(describing: result))", rawText: "")
    }

    /// Subscribe a stream URL for real-time recognition. `radioID` is your
    /// caller-side identifier; `callbacks: "before"` requests song-start callbacks
    /// instead of song-end.
    ///
    /// - Parameter extraParameters: additional form fields the typed params don't
    ///   cover. Typed params (`url`, `radio_id`, `callbacks`) win on collision.
    public func add(
        url: String,
        radioID: Int,
        callbacks: String? = nil,
        extraParameters: [String: String]? = nil
    ) async throws {
        var fields: [String: String] = extraParameters ?? [:]
        fields["url"] = url
        fields["radio_id"] = String(radioID)
        if let callbacks { fields["callbacks"] = callbacks }
        _ = try await post("addStream", fields: fields, policy: mutatingPolicy)
    }

    public func setURL(radioID: Int, url: String) async throws {
        _ = try await post("setStreamUrl", fields: ["radio_id": String(radioID), "url": url], policy: mutatingPolicy)
    }

    public func delete(radioID: Int) async throws {
        _ = try await post("deleteStream", fields: ["radio_id": String(radioID)], policy: mutatingPolicy)
    }

    /// List all streams subscribed on this account.
    public func list() async throws -> [Stream] {
        let result = try await post("getStreams", fields: [:], policy: readPolicy)
        guard let arr = result as? [[String: Any]] else { return [] }
        return try arr.map { try decode(Stream.self, from: $0) }
    }

    /// Compute the 9-char longpoll category locally from the client's current
    /// api_token and `radioID`. Formula: `md5(md5(apiToken) + str(radioID))[..9]`.
    public func deriveLongpollCategory(radioID: Int) -> String {
        return Audd_deriveLongpollCategory(apiToken: http.apiToken, radioID: radioID)
    }

    /// Parse a webhook callback POST body into a typed match or notification.
    ///
    /// - Returns: ``CallbackEvent/match(_:)`` for a recognition event,
    ///   ``CallbackEvent/notification(_:)`` for a stream-lifecycle event.
    /// - Throws: ``AudDError/serializationError(message:rawText:)`` if the body
    ///   isn't valid JSON or carries neither a `result` nor a `notification`.
    ///
    /// This is a static-style pure function on the `Streams` namespace; no
    /// network calls. Use it inside your HTTP handler that receives AudD
    /// callbacks.
    public func parseCallback(_ data: Data) throws -> CallbackEvent {
        return try Audd_parseCallback(data)
    }

    /// Start a long-poll subscription for the given category.
    ///
    /// Returns a ``LongpollPoll`` whose `matches` / `notifications` / `errors`
    /// `AsyncStream`s are filled by a background task. The task exits when
    /// `await poll.close()` is called or a terminal error fires (which is
    /// emitted on `errors` and then closes all three streams). See
    /// ``LongpollPoll`` for how responses are handled.
    ///
    /// The longpoll requests carry no api_token: the category authorizes them.
    ///
    /// On entry, runs a preflight `getCallbackURL()` unless
    /// ``LongpollOptions/skipCallbackCheck`` is set — catches the common
    /// silent-failure mode where no callback URL is configured.
    ///
    /// - Parameters:
    ///   - category: the category derived from ``deriveLongpollCategory(radioID:)``.
    ///   - options: subscription options. Defaults to "start from now, 50s
    ///     timeout, preflight on".
    ///
    /// This is the tokenless / pre-derived-category form. If you have the
    /// `apiToken` and `radioID` locally, use ``longpoll(radioID:options:)``
    /// instead — it derives the category for you.
    public func longpoll(category: String, options: LongpollOptions = LongpollOptions()) async throws -> LongpollPoll {
        if !options.skipCallbackCheck {
            do {
                _ = try await getCallbackURL()
            } catch let AudDError.api(detail) where detail.errorCode == AudDErrorCodes.noCallbackURL {
                throw AudDError.api(AudDAPIErrorDetail(
                    kind: .invalidRequest,
                    errorCode: 0,
                    message: preflightNoCallbackHint,
                    httpStatus: detail.httpStatus,
                    requestID: detail.requestID
                ))
            }
        }
        let endpoint = apiBase.appendingPathComponent("/longpoll").appendingPathComponent("/")
        let fetch = makeLongpollFetch(http: longpollHTTP, endpoint: endpoint, policy: readPolicy)
        return LongpollPoll(
            category: category,
            options: options,
            fetch: fetch
        )
    }

    /// Start a long-poll subscription for the given `radioID`.
    ///
    /// One-step convenience that derives the 9-char category locally from the
    /// configured `apiToken` and the given `radioID`, then delegates to
    /// ``longpoll(category:options:)``. This is the common case when you have
    /// the api_token and radio_id together; for tokenless / share-with-browser
    /// flows where the server has already shipped a category string, use
    /// ``longpoll(category:options:)`` directly.
    ///
    /// - Parameters:
    ///   - radioID: the stream's radio_id (as passed to ``add(url:radioID:callbacks:extraParameters:)``).
    ///   - options: subscription options. Defaults to "start from now, 50s
    ///     timeout, preflight on".
    public func longpoll(radioID: Int, options: LongpollOptions = LongpollOptions()) async throws -> LongpollPoll {
        return try await longpoll(category: deriveLongpollCategory(radioID: radioID), options: options)
    }
}

// MARK: - LongpollPoll

/// Active long-poll subscription. Three typed streams surface its output:
///
/// - ``matches`` yields every recognition event (one per song match).
/// - ``notifications`` yields stream-lifecycle events.
/// - ``errors`` yields a single terminal error and then closes — when an error
///   fires, the consumer is terminal and `matches` / `notifications` close too.
///
/// Each event the server returns is delivered in order; an event that can't
/// be parsed, or a recognition with an empty `results` list, is skipped. The
/// next request resumes after the newest timestamp the server sent. A
/// response that brings no event and no newer timestamp (an unknown or
/// non-JSON body) is followed by a pause before the next request, starting at
/// 1 second and doubling up to 30 seconds. The subscription ends with an error
/// on ``errors`` when the server rejects the request (for example a `timeout`
/// outside 1-120, as ``AudDError/api(_:)`` with kind `.invalidRequest` and the
/// server's text), on an HTTP 4xx, and when network failures or HTTP 5xx
/// responses outlast the retry budget.
///
/// Call ``close()`` to tear down the background poller and close all streams;
/// it also cancels a request the server is still holding open. Closing is
/// idempotent.
///
/// Sample usage:
/// ```swift
/// let poll = try await audd.streams.longpoll(category: cat)
/// defer { Task { await poll.close() } }
///
/// await withTaskGroup(of: Void.self) { group in
///     group.addTask {
///         for await match in poll.matches {
///             print("\(match.song?.artist ?? "?") — \(match.song?.title ?? "?")")
///         }
///     }
///     group.addTask {
///         for await error in poll.errors {
///             print("longpoll stopped: \(error.localizedDescription)")
///         }
///     }
/// }
/// ```
public actor LongpollPoll {
    /// Recognition events. Closed when the poll terminates.
    public nonisolated let matches: AsyncStream<StreamCallbackMatch>
    /// Stream-lifecycle events.
    public nonisolated let notifications: AsyncStream<StreamCallbackNotification>
    /// Single terminal error stream. After an error fires, ``matches`` and
    /// ``notifications`` close too.
    public nonisolated let errors: AsyncStream<Error>

    private let matchesContinuation: AsyncStream<StreamCallbackMatch>.Continuation
    private let notificationsContinuation: AsyncStream<StreamCallbackNotification>.Continuation
    private let errorsContinuation: AsyncStream<Error>.Continuation
    private var task: Task<Void, Never>?
    private var didClose = false

    init(
        category: String,
        options: LongpollOptions,
        fetch: @escaping LongpollFetch,
        idleBackoff: LongpollIdleBackoff = LongpollIdleBackoff(),
        sleep: @escaping LongpollSleep = longpollTaskSleep
    ) {
        var matchesCont: AsyncStream<StreamCallbackMatch>.Continuation!
        let matches = AsyncStream<StreamCallbackMatch> { c in matchesCont = c }
        var notifsCont: AsyncStream<StreamCallbackNotification>.Continuation!
        let notifications = AsyncStream<StreamCallbackNotification> { c in notifsCont = c }
        var errsCont: AsyncStream<Error>.Continuation!
        let errors = AsyncStream<Error> { c in errsCont = c }
        self.matches = matches
        self.notifications = notifications
        self.errors = errors
        self.matchesContinuation = matchesCont
        self.notificationsContinuation = notifsCont
        self.errorsContinuation = errsCont

        // Start the polling task. Capture the continuations directly — the
        // task drives them and closes them on exit. The continuations are
        // Sendable; the task runs detached from the actor.
        let mc = matchesCont!
        let nc = notifsCont!
        let ec = errsCont!
        let sinceTime = options.sinceTime
        let timeout = options.timeout
        self.task = Task.detached {
            await runLongpollLoop(
                category: category,
                sinceTime: sinceTime,
                timeout: timeout,
                fetch: fetch,
                idleBackoff: idleBackoff,
                sleep: sleep,
                matches: mc,
                notifications: nc,
                errors: ec
            )
        }
    }

    /// Stop the background poll and cancel a request that is still waiting on
    /// the server. Idempotent.
    public func close() async {
        if didClose { return }
        didClose = true
        task?.cancel()
        // Close the three streams so any in-flight `for await` exits cleanly
        // even if the task is still mid-fetch.
        matchesContinuation.finish()
        notificationsContinuation.finish()
        errorsContinuation.finish()
    }
}

/// One longpoll GET: the query parameters and the request's timeout.
typealias LongpollFetch = @Sendable (_ params: [String: String], _ requestTimeout: TimeInterval) async throws -> HTTPResponseEnvelope

/// Pause used between longpoll requests; throws when the poll is cancelled.
typealias LongpollSleep = @Sendable (_ seconds: Double) async throws -> Void

let longpollTaskSleep: LongpollSleep = { seconds in
    try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
}

/// Pause schedule after responses that bring nothing new: `initial` seconds,
/// doubling up to `maximum`, back to `initial` once a response delivers an
/// event or a newer timestamp.
struct LongpollIdleBackoff: Sendable {
    var initial: Double = 1
    var maximum: Double = 30
}

/// What one longpoll response yields.
enum LongpollOutcome {
    /// Events to deliver in order, and the `since_time` for the next request
    /// (`nil`: keep the current one).
    case delivered([CallbackEvent], nextSinceTime: Int?)
    /// The subscription ends with this error.
    case terminal(Error)
}

/// Run the long-poll loop. Drives one iteration per server response, parses
/// it into matches and notifications, dispatches onto the typed streams. On
/// terminal error, sends a single error and closes all three streams.
func runLongpollLoop(
    category: String,
    sinceTime: Int?,
    timeout: Int,
    fetch: @escaping LongpollFetch,
    idleBackoff: LongpollIdleBackoff = LongpollIdleBackoff(),
    sleep: @escaping LongpollSleep = longpollTaskSleep,
    matches: AsyncStream<StreamCallbackMatch>.Continuation,
    notifications: AsyncStream<StreamCallbackNotification>.Continuation,
    errors: AsyncStream<Error>.Continuation
) async {
    defer {
        matches.finish()
        notifications.finish()
        errors.finish()
    }
    var cursor = sinceTime
    var nextIdleDelay = idleBackoff.initial
    let requestTimeout = longpollRequestTimeout(timeout)
    while !Task.isCancelled {
        var params: [String: String] = ["category": category, "timeout": String(timeout)]
        if let cursor { params["since_time"] = String(cursor) }
        let env: HTTPResponseEnvelope
        do {
            env = try await fetch(params, requestTimeout)
        } catch {
            // Closing the poll, or the client or consumer behind it, ends
            // the loop without an error.
            if Task.isCancelled || isShutdown(error) { return }
            errors.yield(error)
            return
        }
        if Task.isCancelled { return }

        switch classifyLongpollResponse(env) {
        case .terminal(let error):
            errors.yield(error)
            return
        case .delivered(let events, let nextSinceTime):
            for event in events {
                switch event {
                case .match(let m):
                    matches.yield(m)
                case .notification(let n):
                    notifications.yield(n)
                }
            }
            let advanced = nextSinceTime.map { $0 != cursor } ?? false
            if let nextSinceTime { cursor = nextSinceTime }
            if !events.isEmpty || advanced {
                nextIdleDelay = idleBackoff.initial
                continue
            }
        }

        // Nothing new: wait before asking again.
        let delay = nextIdleDelay
        nextIdleDelay = min(nextIdleDelay * 2, idleBackoff.maximum)
        AudDLog.warning(
            "longpoll response had no events and no new timestamp; next request in \(Int(delay.rounded())) s",
            category: "longpoll"
        )
        do {
            try await sleep(delay)
        } catch {
            return
        }
    }
}

/// `true` for the errors a request ends with when it was cancelled or its
/// client was closed.
func isShutdown(_ error: Error) -> Bool {
    if error is CancellationError || error is ClientClosedError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    if case AudDError.connection(_, let underlying?) = error {
        return isShutdown(underlying)
    }
    return false
}

/// Interpret one longpoll HTTP response. See the file header for the shapes.
func classifyLongpollResponse(_ env: HTTPResponseEnvelope) -> LongpollOutcome {
    let body = env.jsonBody
    if env.httpStatus >= AudDErrorCodes.httpClientErrorFloor {
        var message = "Longpoll endpoint returned HTTP \(env.httpStatus)"
        if let text = body?["error"] as? String, !text.isEmpty {
            message += ": \(text)"
        }
        return .terminal(AudDError.serverError(
            httpStatus: env.httpStatus,
            message: message,
            requestID: env.requestID,
            rawText: env.rawText
        ))
    }
    guard let body else {
        // Empty or non-JSON body: nothing to deliver.
        return .delivered([], nextSinceTime: nil)
    }

    if (body["status"] as? String) == "error" {
        return .terminal(makeAPIError(from: body, httpStatus: env.httpStatus, requestID: env.requestID))
    }
    if let text = body["error"] as? String {
        // An invalid request (bad `timeout`, missing `category`, ...). The
        // same request gets the same error, so the subscription ends here.
        return .terminal(AudDError.api(AudDAPIErrorDetail(
            kind: .invalidRequest,
            errorCode: 0,
            message: text,
            httpStatus: env.httpStatus,
            requestID: env.requestID,
            rawResponse: AnyCodable(body)
        )))
    }

    if let events = body["events"] as? [Any] {
        var delivered: [CallbackEvent] = []
        var newest: Int?
        for case let event as [String: Any] in events {
            if let ts = longpollTimestamp(event["timestamp"]) {
                newest = max(newest ?? ts, ts)
            }
            if let parsed = parseLongpollEventData(event["data"]) {
                delivered.append(parsed)
            }
        }
        return .delivered(delivered, nextSinceTime: newest)
    }

    var delivered: [CallbackEvent] = []
    if body["result"] != nil || body["notification"] != nil,
       let parsed = parseDeliverableCallback(body) {
        delivered.append(parsed)
    }
    return .delivered(delivered, nextSinceTime: longpollTimestamp(body["timestamp"]))
}

/// Parse an event's `data` (a callback body, as an object or as JSON text).
/// `nil` when it can't be parsed or carries no song.
private func parseLongpollEventData(_ data: Any?) -> CallbackEvent? {
    if let object = data as? [String: Any] {
        return parseDeliverableCallback(object)
    }
    if let text = data as? String,
       let bytes = text.data(using: .utf8),
       let object = (try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])) as? [String: Any] {
        return parseDeliverableCallback(object)
    }
    return nil
}

/// Parse a callback body for delivery on a longpoll stream. A recognition
/// with an empty `results` list has nothing to deliver.
private func parseDeliverableCallback(_ object: [String: Any]) -> CallbackEvent? {
    guard let event = try? Audd_parseCallbackObject(object) else { return nil }
    if case .match(let m) = event, m.song == nil { return nil }
    return event
}

/// A millisecond timestamp from a JSON value: a number or a numeric string.
func longpollTimestamp(_ value: Any?) -> Int? {
    switch value {
    case let s as String:
        return Int(s.trimmingCharacters(in: .whitespaces))
    case let i as Int:
        return i
    case let d as Double:
        return d.isFinite ? Int(exactly: d.rounded(.towardZero)) : nil
    default:
        return nil
    }
}

/// Build the longpoll fetch closure used by ``Streams/longpoll(category:options:)``.
/// Requests carry no api_token.
func makeLongpollFetch(
    http: HTTPClient,
    endpoint: URL,
    policy: RetryPolicy
) -> LongpollFetch {
    return { params, requestTimeout in
        return try await runWithRetry(policy: policy) {
            return try await http.get(url: endpoint, params: params, timeout: requestTimeout)
        }
    }
}

// Pure helper functions used by the streams namespace and the LongpollConsumer.

func Audd_deriveLongpollCategory(apiToken: String, radioID: Int) -> String {
    // hex-MD5 of (hex-MD5(apiToken) + str(radioID)), truncated to 9 chars
    let inner = Audd_md5Hex(apiToken)
    let outer = Audd_md5Hex(inner + String(radioID))
    return String(outer.prefix(9))
}

/// Parse a callback POST body (raw bytes) into a typed match or notification.
///
/// Recognition callbacks have an outer `result` block; notification callbacks
/// have a `notification` block; the discrimination is by-key. Exactly one of
/// the two cases is returned.
func Audd_parseCallback(_ data: Data) throws -> CallbackEvent {
    let raw: [String: Any]
    do {
        guard let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw AudDError.serializationError(
                message: "callback body is not a JSON object",
                rawText: String(data: data, encoding: .utf8) ?? ""
            )
        }
        raw = parsed
    } catch let err as AudDError {
        throw err
    } catch {
        throw AudDError.serializationError(
            message: "callback body is not valid JSON: \(error.localizedDescription)",
            rawText: String(data: data, encoding: .utf8) ?? ""
        )
    }
    return try Audd_parseCallbackObject(raw, rawText: String(data: data, encoding: .utf8))
}

/// Parse an already-decoded callback body. `rawText` goes into the error when
/// the body has neither a `result` nor a `notification` block.
func Audd_parseCallbackObject(_ raw: [String: Any], rawText: String? = nil) throws -> CallbackEvent {
    let rawResponse = AnyCodable(raw)

    if let notifDict = raw["notification"] as? [String: Any] {
        let notif = try decode(StreamCallbackNotification.self, from: notifDict)
        let time = raw["time"] as? Int
        // Re-extract extras from the inner notification dict so the public
        // `extras` matches the documented "unknown keys on the notification
        // block" semantic. (`decode` already populates this; we're only
        // attaching `time` and `rawResponse` which the typed initializer
        // doesn't see.)
        let withOuter = StreamCallbackNotification(
            radioID: notif.radioID,
            streamRunning: notif.streamRunning,
            notificationCode: notif.notificationCode,
            notificationMessage: notif.notificationMessage,
            time: time,
            extras: notif.extras,
            rawResponse: rawResponse
        )
        return .notification(withOuter)
    }

    if let resultDict = raw["result"] as? [String: Any] {
        let match = try decode(StreamCallbackMatch.self, from: resultDict)
        let withOuter = StreamCallbackMatch(
            radioID: match.radioID,
            timestamp: match.timestamp,
            playLength: match.playLength,
            song: match.song,
            alternatives: match.alternatives,
            extras: match.extras,
            rawResponse: rawResponse
        )
        return .match(withOuter)
    }

    let text = rawText
        ?? (try? JSONSerialization.data(withJSONObject: raw)).flatMap { String(data: $0, encoding: .utf8) }
        ?? ""
    throw AudDError.serializationError(
        message: "callback body has neither result nor notification",
        rawText: text
    )
}

/// Append `?return=<csv>` (or `&return=`) to a callback URL. Throws on conflict
/// — refusing to silently overwrite. See spec §4.1 (set_callback_url).
func addReturnToURL(_ url: String, returnMetadata: [String]?) throws -> String {
    guard let returnMetadata, !returnMetadata.isEmpty else { return url }
    let metadata = returnMetadata.joined(separator: ",")

    guard var components = URLComponents(string: url) else {
        // Not a URL we can parse — refuse to mutate it; surface as invalid arg.
        throw AudDError.invalidArgument("Could not parse callback URL: \(url)")
    }
    var items = components.queryItems ?? []
    if items.contains(where: { $0.name == "return" }) {
        // Conflict — caller passed both a URL with ?return=... and returnMetadata.
        throw AudDError.api(AudDAPIErrorDetail(
            kind: .invalidRequest,
            errorCode: 0,
            message: "URL already contains a `return` query parameter; pass returnMetadata: nil or remove the parameter from the URL — refusing to silently overwrite.",
            httpStatus: 0,
            requestID: nil
        ))
    }
    items.append(URLQueryItem(name: "return", value: metadata))
    components.queryItems = items
    return components.url?.absoluteString ?? url
}
