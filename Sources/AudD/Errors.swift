// Single error enum for the SDK, mirroring the Python hierarchy via cases plus
// an `errorCode` discriminator on `.api(...)`. See design spec §6.
//
// Pattern-match for type-narrowing:
//   do {
//     let r = try await audd.recognize(...)
//   } catch let AudDError.api(detail) where detail.kind == .authentication {
//     // ...
//   } catch AudDError.connection(_) {
//     // ...
//   }
import Foundation

/// Categories of API-level errors. Maps to the AudD numeric error-code catalog.
public enum AudDErrorKind: Sendable, Equatable {
    case authentication       // 900, 901, 903
    case quota                // 902
    case subscription         // 904, 905
    case customCatalogAccess  // 904 raised from custom_catalog.* specifically
    case invalidRequest       // 50, 51, 600, 601, 602, 700, 701, 702, 906
    case invalidAudio         // 300, 400, 500
    case rateLimit            // 611, HTTP 429
    case streamLimit          // 610
    case notReleased          // 907
    case blocked              // 19, 31337
    case needsUpdate          // 20
    case server               // 100, 1000, generic upstream/non-2xx
}

/// Detail attached to an `.api(...)` error.
public struct AudDAPIErrorDetail: Sendable, Equatable {
    public let kind: AudDErrorKind
    public let errorCode: Int
    public let message: String
    public let httpStatus: Int
    public let requestID: String?
    public let requestedParams: [String: AnyCodable]
    public let requestMethod: String?
    public let brandedMessage: String?
    public let rawResponse: AnyCodable?

    public init(
        kind: AudDErrorKind,
        errorCode: Int,
        message: String,
        httpStatus: Int,
        requestID: String?,
        requestedParams: [String: AnyCodable] = [:],
        requestMethod: String? = nil,
        brandedMessage: String? = nil,
        rawResponse: AnyCodable? = nil
    ) {
        self.kind = kind
        self.errorCode = errorCode
        self.message = message
        self.httpStatus = httpStatus
        self.requestID = requestID
        self.requestedParams = requestedParams
        self.requestMethod = requestMethod
        self.brandedMessage = brandedMessage
        self.rawResponse = rawResponse
    }
}

/// Errors raised by the SDK.
public enum AudDError: Error, Sendable {
    /// API-level error: server responded with `status: error`, or a non-2xx HTTP
    /// status, or otherwise an actionable server failure. See `detail.kind` to
    /// classify and respond.
    case api(AudDAPIErrorDetail)

    /// Server returned HTTP non-2xx with a non-JSON body (gateway HTML page,
    /// timeout text, etc.). Distinct from `.serializationError`.
    case serverError(httpStatus: Int, message: String, requestID: String?, rawText: String)

    /// Network / TLS / read-timeout / DNS failure. No HTTP response was received
    /// (or one was abandoned mid-flight).
    case connection(message: String, underlying: Error?)

    /// Server returned 2xx but the body wasn't valid JSON or wasn't shaped as expected.
    case serializationError(message: String, rawText: String)

    /// Caller-side validation problem (unsupported source, conflicting args, etc).
    /// Distinct from `.api(.invalidRequest)` because nothing was sent to the server.
    case invalidArgument(String)

    /// Retry attempted on an unseekable file-like source. See `Source.stream(...)`
    /// constraints.
    case unsupportedSource(String)

    /// SDK configuration problem detected before any request is sent — e.g.
    /// missing api_token (no explicit value and `AUDD_API_TOKEN` env var unset),
    /// invalid token rotation. See spec §7.11.
    case configuration(String)
}

extension AudDError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .api(let detail):
            return "[#\(detail.errorCode)] \(detail.message)"
        case .serverError(let status, let message, _, _):
            return "AudDServerError: HTTP \(status) — \(message)"
        case .connection(let message, _):
            return "AudDConnectionError: \(message)"
        case .serializationError(let message, _):
            return "AudDSerializationError: \(message)"
        case .invalidArgument(let message):
            return "AudDError: \(message)"
        case .unsupportedSource(let message):
            return "AudDError: \(message)"
        case .configuration(let message):
            return "AudDConfigurationError: \(message)"
        }
    }
}

// MARK: - Code mapping

enum AudDErrorCodes {
    /// Server returns code 51 with `status=error` but the response may also
    /// contain a usable result; we treat this as a deprecation pass-through.
    /// See spec §6.5.
    static let deprecatedParams = 51

    /// `getCallbackUrl` returns code 19 when no callback URL is configured for
    /// the account. The streams namespace catches this specifically during the
    /// longpoll preflight to surface a friendlier message.
    static let noCallbackURL = 19

    static let httpClientErrorFloor = 400
    static let httpServerErrorFloor = 500
    static let httpRequestTimeout = 408
    static let httpTooManyRequests = 429
}

func auddErrorKind(forCode code: Int) -> AudDErrorKind {
    switch code {
    case 900, 901, 903:
        return .authentication
    case 902:
        return .quota
    case 904, 905:
        return .subscription
    case 50, 51, 600, 601, 602, 700, 701, 702, 906:
        return .invalidRequest
    case 300, 400, 500:
        return .invalidAudio
    case 610:
        return .streamLimit
    case 611:
        return .rateLimit
    case 907:
        return .notReleased
    case 19, 31337:
        return .blocked
    case 20:
        return .needsUpdate
    case 100, 1000:
        return .server
    default:
        return .server
    }
}

func brandedMessage(from result: Any?) -> String? {
    guard let dict = result as? [String: Any] else { return nil }
    let artist = dict["artist"] as? String
    let title = dict["title"] as? String
    let parts = [artist, title].compactMap { $0?.isEmpty == false ? $0 : nil }
    return parts.isEmpty ? nil : parts.joined(separator: " — ")
}

/// Override message for 904 raised from `custom_catalog.add` specifically. See spec §6.4.
func customCatalogAccessMessage(serverMessage: String) -> String {
    return """
    Adding songs to your custom catalog requires enterprise access that isn't enabled on your account.

    Note: the custom-catalog endpoint is for adding songs to your private fingerprint database, not for music recognition. If you intended to identify music, use recognize(...) (or recognizeEnterprise(...) for files longer than 25 seconds) instead.

    To request custom-catalog access, contact api@audd.io.

    [Server message: \(serverMessage)]
    """
}

/// Translate a server `status: error` body into an `AudDError.api(...)`.
///
/// `customCatalogContext` flips a 904 from `.subscription` to `.customCatalogAccess`
/// and rewrites the user-facing message per spec §6.4.
func makeAPIError(
    from body: [String: Any],
    httpStatus: Int,
    requestID: String?,
    customCatalogContext: Bool = false
) -> AudDError {
    let err = body["error"] as? [String: Any] ?? [:]
    let code = (err["error_code"] as? Int) ?? Int((err["error_code"] as? String) ?? "0") ?? 0
    let message = (err["error_message"] as? String) ?? ""

    var kind = auddErrorKind(forCode: code)
    var finalMessage = message

    if customCatalogContext, kind == .subscription {
        kind = .customCatalogAccess
        finalMessage = customCatalogAccessMessage(serverMessage: message)
    }

    let requestedParamsRaw = (body["request_params"] as? [String: Any])
        ?? (body["requested_params"] as? [String: Any])
        ?? [:]
    var requestedParams: [String: AnyCodable] = [:]
    for (k, v) in requestedParamsRaw {
        requestedParams[k] = AnyCodable(v)
    }

    let detail = AudDAPIErrorDetail(
        kind: kind,
        errorCode: code,
        message: finalMessage,
        httpStatus: httpStatus,
        requestID: requestID,
        requestedParams: requestedParams,
        requestMethod: body["request_api_method"] as? String,
        brandedMessage: brandedMessage(from: body["result"]),
        rawResponse: AnyCodable(body)
    )
    return .api(detail)
}
