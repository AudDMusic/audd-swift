// Streams namespace — set/getCallbackUrl, addStream, longpoll with preflight, etc.
//
// `longpoll(...)` returns an `AsyncThrowingStream<[String: AnyCodable], Error>`
// (effectively, the parsed JSON body of each iteration).
//
// The longpoll preflight (default-on) calls getCallbackUrl once before
// subscribing; when the server returns code 19, we surface a friendlier
// `AudDError.api(.invalidRequest)` with a URL-config hint. Pass
// `skipCallbackCheck: true` to bypass.
// `@preconcurrency import` for Foundation/FoundationNetworking — see AudD.swift
// for the rationale (URL/URLSession Sendable gap on Linux/Swift 5.10).
@preconcurrency import Foundation

#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

let preflightNoCallbackHint = """
Longpoll won't deliver events because no callback URL is configured for this account. \
Set one first via streams.setCallbackURL(...) — `https://audd.tech/empty/` is fine if \
you only want longpolling and don't need a real receiver. \
To skip this check, pass skipCallbackCheck: true.
"""

public struct Streams: Sendable {
    let http: HTTPClient
    let apiBase: URL
    let apiToken: String
    let readPolicy: RetryPolicy
    let mutatingPolicy: RetryPolicy

    init(http: HTTPClient, apiBase: URL, apiToken: String, readPolicy: RetryPolicy, mutatingPolicy: RetryPolicy) {
        self.http = http
        self.apiBase = apiBase
        self.apiToken = apiToken
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
    public func setCallbackURL(_ url: String, returnMetadata: [String]? = nil) async throws {
        let merged = try addReturnToURL(url, returnMetadata: returnMetadata)
        _ = try await post("setCallbackUrl", fields: ["url": merged], policy: mutatingPolicy)
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
    public func add(url: String, radioID: Int, callbacks: String? = nil) async throws {
        var fields: [String: String] = ["url": url, "radio_id": String(radioID)]
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

    /// Compute the 9-char longpoll category locally from `apiToken` + `radioID`.
    /// Formula: `md5(md5(apiToken) + str(radioID))[..9]`.
    public func deriveLongpollCategory(radioID: Int) -> String {
        return Audd_deriveLongpollCategory(apiToken: apiToken, radioID: radioID)
    }

    /// Parse a webhook callback POST body into a typed payload.
    public func parseCallback(_ body: [String: Any]) throws -> StreamCallbackPayload {
        return try StreamCallbackPayload.parse(body)
    }

    /// Subscribe to longpoll events for the given category.
    ///
    /// Returns an `AsyncThrowingStream` — iterate with `for try await event in ...`.
    /// On HTTP non-2xx, throws `AudDError.serverError`. On bad JSON, throws
    /// `AudDError.serializationError`.
    ///
    /// - Parameters:
    ///   - category: the category derived from `deriveLongpollCategory(radioID:)`.
    ///   - sinceTime: optional starting timestamp (server-supplied).
    ///   - timeout: per-request long-poll timeout in seconds (default 50).
    ///   - skipCallbackCheck: when `false` (default), preflights `getCallbackURL`
    ///     once before subscribing, raising a helpful error if code 19. Pass
    ///     `true` to skip — useful for test harnesses.
    public func longpoll(
        category: String,
        sinceTime: Int? = nil,
        timeout: Int = 50,
        skipCallbackCheck: Bool = false
    ) -> AsyncThrowingStream<[String: AnyCodable], Error> {
        let http = self.http
        let apiBase = self.apiBase
        let policy = self.readPolicy
        let needPreflight = !skipCallbackCheck
        // Capture self for preflight call before we spin the stream. Marked
        // `@Sendable` so the AsyncThrowingStream task closure can capture it
        // under strict-concurrency checking.
        let preflight: @Sendable () async throws -> Void = { [self] in
            if !needPreflight { return }
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

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await preflight()
                    var cursor = sinceTime
                    while !Task.isCancelled {
                        var paramsBuilder: [String: String] = ["category": category, "timeout": String(timeout)]
                        if let cursor { paramsBuilder["since_time"] = String(cursor) }
                        // Capture an immutable snapshot for the @Sendable closure.
                        let params = paramsBuilder
                        let envelope = try await runWithRetry(policy: policy) {
                            return try await http.get(url: apiBase.appendingPathComponent("/longpoll").appendingPathComponent("/"), params: params, includeAPIToken: false)
                        }
                        if envelope.httpStatus >= AudDErrorCodes.httpClientErrorFloor {
                            throw AudDError.serverError(
                                httpStatus: envelope.httpStatus,
                                message: "Longpoll endpoint returned HTTP \(envelope.httpStatus)",
                                requestID: envelope.requestID,
                                rawText: envelope.rawText
                            )
                        }
                        guard let body = envelope.jsonBody else {
                            throw AudDError.serializationError(message: "Longpoll response was not a JSON object", rawText: envelope.rawText)
                        }
                        // Convert [String: Any] to [String: AnyCodable] for delivery.
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
            continuation.onTermination = { _ in
                task.cancel()
            }
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
