// Cost-aware retry policy. See spec §7.1.
//
//   READ        — idempotent reads (streams.list, streams.getCallbackUrl):
//                 retry on 408 / 429 / 5xx + any connection error.
//   RECOGNITION — recognize, recognizeEnterprise, advanced.findLyrics, advanced.rawRequest:
//                 retry on pre-upload connection failures + 5xx.
//                 DO NOT retry on read-timeout-after-upload (cost protection).
//   MUTATING    — streams.setCallbackUrl, streams.add, streams.delete,
//                 customCatalog.add: retry only on pre-upload connection failures.
//                 DO NOT retry on 5xx (the side effect may have happened).
import Foundation

public enum RetryClass: Sendable {
    case read
    case recognition
    case mutating
}

public struct RetryPolicy: Sendable {
    public let retryClass: RetryClass
    public let maxAttempts: Int
    public let backoffFactor: Double
    public let backoffMax: Double

    public init(
        retryClass: RetryClass,
        maxAttempts: Int = 3,
        backoffFactor: Double = 0.5,
        backoffMax: Double = 30.0
    ) {
        self.retryClass = retryClass
        self.maxAttempts = maxAttempts
        self.backoffFactor = backoffFactor
        self.backoffMax = backoffMax
    }
}

func backoffDelay(attempt: Int, policy: RetryPolicy) -> Double {
    let base = min(policy.backoffFactor * pow(2.0, Double(attempt)), policy.backoffMax)
    let jitter = 0.5 + Double.random(in: 0..<1)
    return base * jitter
}

func shouldRetryStatus(_ status: Int, retryClass: RetryClass) -> Bool {
    switch retryClass {
    case .read:
        return status == AudDErrorCodes.httpRequestTimeout
            || status == AudDErrorCodes.httpTooManyRequests
            || status >= AudDErrorCodes.httpServerErrorFloor
    case .recognition:
        return status >= AudDErrorCodes.httpServerErrorFloor
    case .mutating:
        return false
    }
}

/// Translate a URLError-or-similar into "should we retry" by retry class.
///
/// We don't have post-vs-pre upload visibility from URLSession on Linux; the
/// .recognition / .mutating policies treat connection-class failures (timeouts
/// while connecting, DNS, etc.) as retry-eligible, and treat the catch-all as
/// non-retryable to avoid double-billing on read-timeouts after the body was
/// already sent. Best-effort heuristic.
func shouldRetryError(_ error: Error, retryClass: RetryClass) -> Bool {
    let urlError = error as? URLError
    switch retryClass {
    case .read:
        return urlError != nil
    case .recognition, .mutating:
        guard let code = urlError?.code else { return false }
        switch code {
        case .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .timedOut,
             .secureConnectionFailed,
             .networkConnectionLost,
             .notConnectedToInternet:
            return true
        default:
            return false
        }
    }
}

/// Run an async operation with cost-aware retry semantics.
func withRetry<T>(
    policy: RetryPolicy,
    operation: @Sendable () async throws -> RetryableResponse<T>
) async throws -> T {
    var lastError: Error?
    for attempt in 0..<policy.maxAttempts {
        do {
            let response = try await operation()
            if let body = response.successBody {
                return body
            }
            // We have a response we'd retry (5xx etc).
            if !shouldRetryStatus(response.status, retryClass: policy.retryClass) {
                // Translate to error and surface.
                throw response.makeError()
            }
            if attempt + 1 >= policy.maxAttempts {
                throw response.makeError()
            }
        } catch let err as AudDError {
            // AudDError surfaced from within the operation — surface unchanged.
            // (We use this for shaping non-retry-eligible API errors.)
            throw err
        } catch {
            lastError = error
            if !shouldRetryError(error, retryClass: policy.retryClass) {
                throw AudDError.connection(message: error.localizedDescription, underlying: error)
            }
            if attempt + 1 >= policy.maxAttempts {
                throw AudDError.connection(message: error.localizedDescription, underlying: error)
            }
        }
        let delay = backoffDelay(attempt: attempt, policy: policy)
        let nanos = UInt64(delay * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
    }
    if let lastError {
        throw AudDError.connection(message: lastError.localizedDescription, underlying: lastError)
    }
    throw AudDError.connection(message: "retry loop exhausted without response", underlying: nil)
}

/// Wrapper used by `withRetry`. Either contains the success body (in which
/// case we return) or a "wait and possibly retry" payload (status + raw + ID)
/// from which we either retry or build an `AudDError` once attempts are exhausted.
struct RetryableResponse<T> {
    let successBody: T?
    let status: Int
    let rawText: String
    let requestID: String?

    static func success(_ value: T, status: Int = 200, rawText: String = "", requestID: String? = nil) -> RetryableResponse<T> {
        RetryableResponse(successBody: value, status: status, rawText: rawText, requestID: requestID)
    }

    static func retryable(status: Int, rawText: String, requestID: String?) -> RetryableResponse<T> {
        RetryableResponse(successBody: nil, status: status, rawText: rawText, requestID: requestID)
    }

    func makeError() -> AudDError {
        return .serverError(httpStatus: status, message: "HTTP \(status) — \(truncated(rawText))", requestID: requestID, rawText: rawText)
    }

    private func truncated(_ s: String) -> String {
        if s.count <= 200 { return s }
        return String(s.prefix(200)) + "…"
    }
}
