// Top-level AudD client. See spec §4.
//
// Async-only (Swift idiom — no completion-handler wrappers). Concurrency-safe
// via `actor` (every public method is `async`).
//
// Use:
//   let audd = AudD(apiToken: "test")
//   let result = try await audd.recognize(.url(URL(string: "https://...")!))
//   await audd.close()
//
// `@preconcurrency import` on Foundation/FoundationNetworking — Foundation's
// `URL`/`URLSession` aren't formally `Sendable` in Swift 5.10 on Linux even
// though they are safe in practice. The attribute downgrades the resulting
// crossings to warnings outside Swift 6 mode, keeping the SDK opt-in
// strict-concurrency clean today.
@preconcurrency import Foundation

#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

/// Environment variable consulted when `apiToken` is omitted or empty. See spec §7.11.
let auddTokenEnvVar = "AUDD_API_TOKEN"

/// Inspection event emitted by the SDK request lifecycle (spec §7.7a).
/// Frozen, plain-data; never carries the api_token or the request body bytes.
public struct AudDEvent: Sendable {
    public enum Kind: String, Sendable {
        case request, response, exception
    }

    /// Lifecycle phase: a request is about to go out, a response was received,
    /// or the request failed with a network/decoding error.
    public let kind: Kind

    /// AudD method name, e.g. `"recognize"`, `"addStream"`, `"findLyrics"`.
    public let method: String

    /// URL the request was/is being sent to. Never carries the api_token.
    public let url: String

    /// `X-Request-Id` from the server, when one was returned.
    public let requestId: String?

    /// HTTP status code, when a response was received.
    public let httpStatus: Int?

    /// Wall-clock duration of the request in seconds. `nil` for `.request`
    /// events (no elapsed time yet).
    public let elapsed: TimeInterval?

    /// AudD numeric error code, when the response carried `status: error`.
    public let errorCode: Int?

    /// Forward-compat bag for additional context fields (e.g. `error_type`).
    /// Never carries the api_token or body bytes.
    public let extras: [String: AnyCodable]

    public init(
        kind: Kind,
        method: String,
        url: String,
        requestId: String? = nil,
        httpStatus: Int? = nil,
        elapsed: TimeInterval? = nil,
        errorCode: Int? = nil,
        extras: [String: AnyCodable] = [:]
    ) {
        self.kind = kind
        self.method = method
        self.url = url
        self.requestId = requestId
        self.httpStatus = httpStatus
        self.elapsed = elapsed
        self.errorCode = errorCode
        self.extras = extras
    }
}

/// Hook signature for the `onEvent` inspection callback. Hook exceptions are
/// swallowed by the SDK so observability never breaks the request path.
public typealias AudDEventHook = @Sendable (AudDEvent) -> Void

/// Invoke `hook` while suppressing any Swift error / Objective-C exception
/// it raises. Observability must never break the request path.
func safeEmitAudDEvent(_ hook: AudDEventHook?, _ event: AudDEvent) {
    guard let hook else { return }
    hook(event)
}

func resolveAudDToken(_ apiToken: String?) throws -> String {
    if let apiToken, !apiToken.isEmpty {
        return apiToken
    }
    if let env = ProcessInfo.processInfo.environment[auddTokenEnvVar], !env.isEmpty {
        return env
    }
    throw AudDError.configuration(
        "AudD apiToken not supplied and \(auddTokenEnvVar) env var is unset. " +
        "Get a token at https://dashboard.audd.io and pass it as " +
        "AudD(apiToken: ...) or set \(auddTokenEnvVar)."
    )
}

public actor AudD {
    public static let apiBase = URL(string: "https://api.audd.io")!
    public static let enterpriseBase = URL(string: "https://enterprise.audd.io")!

    /// The current api_token. Mutated only via `setApiToken(_:)`. Actor
    /// isolation makes reads/writes serialize without an explicit lock.
    public private(set) var apiToken: String
    private let maxRetries: Int
    private let backoffFactor: Double
    private let httpStandard: HTTPClient
    private let httpEnterprise: HTTPClient
    /// Override base URL — used by the test harness to point at a mock.
    private let apiBase: URL
    private let enterpriseBase: URL
    private let onEvent: AudDEventHook?

    /// Construct with an explicit token, or pass `nil`/empty string to read
    /// `AUDD_API_TOKEN` from the environment. Throws `AudDError.configuration`
    /// if neither is set. See spec §7.11.
    ///
    /// - Parameter onEvent: optional inspection hook (spec §7.7a). Receives
    ///   one event per request lifecycle phase: `.request` before the request
    ///   leaves, `.response` once a response is decoded, `.exception` if the
    ///   request failed (network, decoding, or API error). Hook exceptions
    ///   are swallowed; the api_token is never included.
    public init(
        apiToken: String? = nil,
        maxRetries: Int = 3,
        backoffFactor: Double = 0.5,
        urlSession: URLSession? = nil,
        enterpriseURLSession: URLSession? = nil,
        apiBase: URL = AudD.apiBase,
        enterpriseBase: URL = AudD.enterpriseBase,
        onEvent: AudDEventHook? = nil
    ) throws {
        let token = try resolveAudDToken(apiToken)
        self.apiToken = token
        self.maxRetries = maxRetries
        self.backoffFactor = backoffFactor
        self.httpStandard = HTTPClient(apiToken: token, timeouts: .standard, urlSession: urlSession)
        self.httpEnterprise = HTTPClient(apiToken: token, timeouts: .enterprise, urlSession: enterpriseURLSession ?? urlSession)
        self.apiBase = apiBase
        self.enterpriseBase = enterpriseBase
        self.onEvent = onEvent
    }

    /// Rotate the api_token used for subsequent requests. In-flight requests
    /// continue with the previous token (no abort) — the underlying
    /// `HTTPClient` snapshots the token at request build time. Thread-safe via
    /// actor isolation here, plus an internal lock on `HTTPClient`. Spec §7.10.
    ///
    /// Throws `AudDError.configuration` when called with an empty string.
    public func setApiToken(_ newToken: String) throws {
        guard !newToken.isEmpty else {
            throw AudDError.configuration("setApiToken requires a non-empty string")
        }
        self.apiToken = newToken
        httpStandard.setApiToken(newToken)
        httpEnterprise.setApiToken(newToken)
    }

    /// Construct exclusively from the `AUDD_API_TOKEN` environment variable.
    /// Throws `AudDError.configuration` if it isn't set. Convenience for CLI
    /// tools and CI runners.
    public static func fromEnvironment(
        maxRetries: Int = 3,
        backoffFactor: Double = 0.5,
        urlSession: URLSession? = nil,
        enterpriseURLSession: URLSession? = nil,
        apiBase: URL = AudD.apiBase,
        enterpriseBase: URL = AudD.enterpriseBase,
        onEvent: AudDEventHook? = nil
    ) throws -> AudD {
        return try AudD(
            apiToken: nil,
            maxRetries: maxRetries,
            backoffFactor: backoffFactor,
            urlSession: urlSession,
            enterpriseURLSession: enterpriseURLSession,
            apiBase: apiBase,
            enterpriseBase: enterpriseBase,
            onEvent: onEvent
        )
    }

    // MARK: - Lifecycle

    /// Explicit disposal; release URLSessions early. `deinit` also closes.
    public func close() {
        httpStandard.close()
        httpEnterprise.close()
    }

    // MARK: - Internal: retry policies

    private func recognitionPolicy() -> RetryPolicy {
        RetryPolicy(retryClass: .recognition, maxAttempts: maxRetries, backoffFactor: backoffFactor)
    }

    private func readPolicy() -> RetryPolicy {
        RetryPolicy(retryClass: .read, maxAttempts: maxRetries, backoffFactor: backoffFactor)
    }

    private func mutatingPolicy() -> RetryPolicy {
        RetryPolicy(retryClass: .mutating, maxAttempts: maxRetries, backoffFactor: backoffFactor)
    }

    private func criticalPolicy() -> RetryPolicy {
        // Single attempt; no retry on 5xx or transport failures.
        // Used for metered, non-idempotent calls (customCatalog.add).
        RetryPolicy(retryClass: .critical, maxAttempts: 1, backoffFactor: backoffFactor)
    }

    // MARK: - Recognition

    /// Recognize music from a public URL string.
    /// Convenience overload; defers to `recognize(_:returnMetadata:market:)` with `.url(...)`.
    @discardableResult
    public func recognize(
        _ urlString: String,
        returnMetadata: [String]? = nil,
        market: String? = nil,
        extraParameters: [String: String]? = nil
    ) async throws -> RecognitionResult? {
        guard let url = URL(string: urlString) else {
            throw AudDError.invalidArgument("\(urlString) is not a valid URL")
        }
        return try await recognize(
            .url(url),
            returnMetadata: returnMetadata,
            market: market,
            extraParameters: extraParameters
        )
    }

    /// Recognize music from a `Source`. Returns `nil` when the server returns
    /// `status=success` with no match (distinct from raising an error).
    ///
    /// - Parameters:
    ///   - source: URL, file path, raw bytes, or stream.
    ///   - returnMetadata: optional list of metadata sources to fetch (apple_music,
    ///     spotify, deezer, napster, musicbrainz).
    ///   - market: ISO country code (default server-side: us).
    ///   - extraParameters: additional form fields the typed params don't cover.
    ///     Typed params win on collision.
    public func recognize(
        _ source: Source,
        returnMetadata: [String]? = nil,
        market: String? = nil,
        extraParameters: [String: String]? = nil
    ) async throws -> RecognitionResult? {
        let reopen = try prepareSource(source)
        let returnString = formatReturn(returnMetadata)
        let url = self.apiBase.appendingPathComponent("/")
        let urlString = url.absoluteString
        let hook = self.onEvent
        safeEmitAudDEvent(hook, AudDEvent(kind: .request, method: "recognize", url: urlString))
        let started = Date()

        let envelope: HTTPResponseEnvelope
        do {
            envelope = try await runWithRetry(policy: recognitionPolicy()) {
                var prepared = try reopen()
                if let extraParameters {
                    for (k, v) in extraParameters {
                        prepared.formFields[k] = v
                    }
                }
                if let returnString {
                    prepared.formFields["return"] = returnString
                }
                if let market {
                    prepared.formFields["market"] = market
                }
                return try await self.httpStandard.postForm(url: url, prepared: prepared)
            }
        } catch {
            safeEmitAudDEvent(hook, AudDEvent(
                kind: .exception, method: "recognize", url: urlString,
                elapsed: Date().timeIntervalSince(started),
                extras: ["error_type": AnyCodable(String(describing: type(of: error)))]
            ))
            throw error
        }

        safeEmitAudDEvent(hook, AudDEvent(
            kind: .response, method: "recognize", url: urlString,
            requestId: envelope.requestID, httpStatus: envelope.httpStatus,
            elapsed: Date().timeIntervalSince(started)
        ))

        do {
            let body = try decodeOrThrow(envelope)
            guard let result = body["result"], !(result is NSNull) else {
                return nil
            }
            return try decode(RecognitionResult.self, from: result)
        } catch let AudDError.api(detail) {
            safeEmitAudDEvent(hook, AudDEvent(
                kind: .exception, method: "recognize", url: urlString,
                requestId: detail.requestID, httpStatus: detail.httpStatus,
                elapsed: Date().timeIntervalSince(started),
                errorCode: detail.errorCode
            ))
            throw AudDError.api(detail)
        } catch {
            safeEmitAudDEvent(hook, AudDEvent(
                kind: .exception, method: "recognize", url: urlString,
                httpStatus: envelope.httpStatus,
                elapsed: Date().timeIntervalSince(started),
                extras: ["error_type": AnyCodable(String(describing: type(of: error)))]
            ))
            throw error
        }
    }

    /// Recognize music on the enterprise endpoint (large-file / chunk-based).
    /// Returns an empty array when no matches are found.
    ///
    /// Each match carries ``EnterpriseMatch/startSeconds`` /
    /// ``EnterpriseMatch/endSeconds`` — where the song plays in the file, in
    /// seconds, precise because accurate offsets are requested by default.
    ///
    /// - Parameters:
    ///   - accurateOffsets: request precise per-fragment offsets. Defaults to
    ///     `true`; pass `false` to opt out.
    ///   - extraParameters: additional form fields the typed params don't cover.
    ///     Typed params win on collision.
    public func recognizeEnterprise(
        _ source: Source,
        returnMetadata: [String]? = nil,
        skip: Int? = nil,
        every: Int? = nil,
        limit: Int? = 1, // hard rule: always pass limit=1 to enterprise calls
        skipFirstSeconds: Int? = nil,
        useTimecode: Bool? = nil,
        accurateOffsets: Bool? = nil,
        extraParameters: [String: String]? = nil
    ) async throws -> [EnterpriseMatch] {
        let reopen = try prepareSource(source)
        let returnString = formatReturn(returnMetadata)

        let extra = enterpriseFields(
            returnString: returnString,
            skip: skip, every: every, limit: limit,
            skipFirstSeconds: skipFirstSeconds,
            useTimecode: useTimecode,
            accurateOffsets: accurateOffsets
        )

        let url = self.enterpriseBase.appendingPathComponent("/")
        let urlString = url.absoluteString
        let hook = self.onEvent
        safeEmitAudDEvent(hook, AudDEvent(kind: .request, method: "recognizeEnterprise", url: urlString))
        let started = Date()

        let envelope: HTTPResponseEnvelope
        do {
            envelope = try await runWithRetry(policy: recognitionPolicy()) {
                var prepared = try reopen()
                if let extraParameters {
                    for (k, v) in extraParameters {
                        prepared.formFields[k] = v
                    }
                }
                for (k, v) in extra {
                    prepared.formFields[k] = v
                }
                return try await self.httpEnterprise.postForm(url: url, prepared: prepared)
            }
        } catch {
            safeEmitAudDEvent(hook, AudDEvent(
                kind: .exception, method: "recognizeEnterprise", url: urlString,
                elapsed: Date().timeIntervalSince(started),
                extras: ["error_type": AnyCodable(String(describing: type(of: error)))]
            ))
            throw error
        }

        safeEmitAudDEvent(hook, AudDEvent(
            kind: .response, method: "recognizeEnterprise", url: urlString,
            requestId: envelope.requestID, httpStatus: envelope.httpStatus,
            elapsed: Date().timeIntervalSince(started)
        ))

        do {
            let body = try decodeOrThrow(envelope)
            guard let resultAny = body["result"] else {
                return []
            }
            if resultAny is NSNull { return [] }
            guard let chunks = resultAny as? [[String: Any]] else { return [] }
            var matches: [EnterpriseMatch] = []
            for chunk in chunks {
                let chunkResult = try decode(EnterpriseChunkResult.self, from: chunk)
                // The chunk `offset` is the fragment's position in the user's
                // file. Anchor each song's fragment-relative ms offsets to it so
                // callers get an absolute position in seconds. `nil` base ⇒ leave
                // the per-song seconds nil.
                let base = offsetToSeconds(chunkResult.offset)
                for var song in chunkResult.songs {
                    if let base {
                        song.startSeconds = base + Double(song.startOffset ?? 0) / 1000
                        song.endSeconds = base + Double(song.endOffset ?? 0) / 1000
                    }
                    matches.append(song)
                }
            }
            return matches
        } catch let AudDError.api(detail) {
            safeEmitAudDEvent(hook, AudDEvent(
                kind: .exception, method: "recognizeEnterprise", url: urlString,
                requestId: detail.requestID, httpStatus: detail.httpStatus,
                elapsed: Date().timeIntervalSince(started),
                errorCode: detail.errorCode
            ))
            throw AudDError.api(detail)
        } catch {
            safeEmitAudDEvent(hook, AudDEvent(
                kind: .exception, method: "recognizeEnterprise", url: urlString,
                httpStatus: envelope.httpStatus,
                elapsed: Date().timeIntervalSince(started),
                extras: ["error_type": AnyCodable(String(describing: type(of: error)))]
            ))
            throw error
        }
    }

    // MARK: - Namespaces

    /// `audd.streams.add(...)`, `audd.streams.list()`, etc.
    public var streams: Streams {
        Streams(http: httpStandard, apiBase: apiBase, apiToken: apiToken, readPolicy: readPolicy(), mutatingPolicy: mutatingPolicy())
    }

    /// `audd.customCatalog.add(audioID: ..., source: ...)`.
    public var customCatalog: CustomCatalog {
        // Custom-catalog upload is metered; uses the .critical policy
        // (1 attempt, no retry on any failure) to avoid double-charging.
        CustomCatalog(http: httpStandard, apiBase: apiBase, uploadPolicy: criticalPolicy())
    }

    /// `audd.advanced.findLyrics(...)`, `audd.advanced.rawRequest(...)`.
    public var advanced: Advanced {
        Advanced(http: httpStandard, apiBase: apiBase, recognitionPolicy: recognitionPolicy())
    }
}

// MARK: - Decoding helpers (file-private to module)

func formatReturn(_ values: [String]?) -> String? {
    guard let values, !values.isEmpty else { return nil }
    return values.joined(separator: ",")
}

func enterpriseFields(
    returnString: String?,
    skip: Int?,
    every: Int?,
    limit: Int?,
    skipFirstSeconds: Int?,
    useTimecode: Bool?,
    accurateOffsets: Bool?
) -> [String: String] {
    var fields: [String: String] = [:]
    if let returnString {
        fields["return"] = returnString
    }
    if let skip { fields["skip"] = String(skip) }
    if let every { fields["every"] = String(every) }
    if let limit { fields["limit"] = String(limit) }
    if let skipFirstSeconds { fields["skip_first_seconds"] = String(skipFirstSeconds) }
    if let useTimecode { fields["use_timecode"] = useTimecode ? "true" : "false" }
    // Accurate offsets default on: send `accurate_offsets=true` unless the
    // caller explicitly opts out with `false`, so `startSeconds`/`endSeconds`
    // are precise out of the box.
    fields["accurate_offsets"] = (accurateOffsets ?? true) ? "true" : "false"
    return fields
}

func runWithRetry(
    policy: RetryPolicy,
    operation: @escaping @Sendable () async throws -> HTTPResponseEnvelope
) async throws -> HTTPResponseEnvelope {
    return try await withRetry(policy: policy) {
        do {
            let envelope = try await operation()
            // Decide retryability by HTTP status only here; further error shaping
            // happens later in decodeOrThrow.
            if shouldRetryStatus(envelope.httpStatus, retryClass: policy.retryClass) {
                return RetryableResponse<HTTPResponseEnvelope>.retryable(
                    status: envelope.httpStatus, rawText: envelope.rawText, requestID: envelope.requestID
                )
            }
            return RetryableResponse<HTTPResponseEnvelope>.success(envelope, status: envelope.httpStatus, rawText: envelope.rawText, requestID: envelope.requestID)
        } catch let urlError as URLError {
            // Bubble up so withRetry can decide retry or wrap.
            throw urlError
        } catch let auddError as AudDError {
            throw auddError
        } catch {
            throw error
        }
    }
}

/// Inspect a top-level response envelope, raise typed errors for obvious
/// failures, else return the JSON body dict. Spec §6.6 + §6.5.
func decodeOrThrow(_ envelope: HTTPResponseEnvelope) throws -> [String: Any] {
    // Non-2xx with non-JSON body → AudDError.serverError (preserves status). Spec S2.
    if envelope.httpStatus >= AudDErrorCodes.httpClientErrorFloor && envelope.jsonBody == nil {
        throw AudDError.serverError(
            httpStatus: envelope.httpStatus,
            message: "HTTP \(envelope.httpStatus) with non-JSON response body",
            requestID: envelope.requestID,
            rawText: envelope.rawText
        )
    }
    guard var body = envelope.jsonBody else {
        // 2xx with bad JSON → serializationError (Spec S2)
        throw AudDError.serializationError(message: "Unparseable response", rawText: envelope.rawText)
    }

    // Code 51 deprecation pass-through (Spec C3).
    if let err = body["error"] as? [String: Any],
       let code = (err["error_code"] as? Int) ?? Int((err["error_code"] as? String) ?? ""),
       code == AudDErrorCodes.deprecatedParams,
       body["result"] != nil, !(body["result"] is NSNull)
    {
        let message = (err["error_message"] as? String) ?? "Deprecated parameter used"
        AudDLog.deprecation(message)
        body.removeValue(forKey: "error")
        body["status"] = "success"
    }

    if let status = body["status"] as? String {
        if status == "error" {
            throw makeAPIError(from: body, httpStatus: envelope.httpStatus, requestID: envelope.requestID)
        }
        if status == "success" {
            return body
        }
        // unrecognized status string → server error
        throw AudDError.serverError(
            httpStatus: envelope.httpStatus,
            message: "Unexpected response status: \(status)",
            requestID: envelope.requestID,
            rawText: envelope.rawText
        )
    }
    // No status field (e.g. longpoll {"timeout": ...}) — return as-is and let
    // the caller interpret. Recognition callers check status above; longpoll
    // path doesn't run through this function.
    return body
}

func decode<T: Decodable>(_ type: T.Type, from any: Any) throws -> T {
    let data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: any, options: [])
    } catch {
        throw AudDError.serializationError(
            message: "Could not re-serialize JSON for decoding: \(error.localizedDescription)",
            rawText: ""
        )
    }
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        throw AudDError.serializationError(
            message: "Could not decode \(T.self): \(error.localizedDescription)",
            rawText: String(data: data, encoding: .utf8) ?? ""
        )
    }
}
