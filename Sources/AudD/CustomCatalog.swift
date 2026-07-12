// Custom-catalog endpoint. NOT for music recognition — see method docstring.
// `@preconcurrency import` for Foundation/FoundationNetworking — see AudD.swift
// for the rationale (URL/URLSession Sendable gap on Linux/Swift 5.10).
@preconcurrency import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CustomCatalog: Sendable {
    let http: HTTPClient
    let apiBase: URL
    /// Retry policy used for metered upload calls. Always the `.critical`
    /// class (single attempt, no retry on 5xx or transport failures) so a
    /// transient failure surfaces cleanly instead of silently re-billing.
    let uploadPolicy: RetryPolicy

    init(http: HTTPClient, apiBase: URL, uploadPolicy: RetryPolicy) {
        self.http = http
        self.apiBase = apiBase
        self.uploadPolicy = uploadPolicy
    }

    /// **This is NOT how you submit audio for music recognition.** For
    /// recognition, use `recognize(...)` (or `recognizeEnterprise(...)` for
    /// files longer than 25 seconds). This method adds a song to your
    /// **private fingerprint catalog** so AudD's recognition can later identify
    /// *your own* tracks for *your account only*. Requires special access —
    /// contact api@audd.io if you need it enabled.
    ///
    /// Calling this again with the same `audioID` re-fingerprints that slot.
    /// There is no public list/delete endpoint; track `audioID` <-> song
    /// mappings on your side.
    ///
    /// Upload is metered, so this method uses a no-retry policy: a 5xx or
    /// pre-upload transport failure surfaces directly to the caller. The
    /// caller decides whether to retry, with full visibility into how many
    /// attempts have been billed.
    public func add(audioID: Int, source: Source) async throws {
        let reopen = try prepareSource(source)
        let envelope = try await runWithRetry(policy: uploadPolicy) {
            var prepared = try reopen()
            prepared.formFields["audio_id"] = String(audioID)
            return try await self.http.postForm(url: self.apiBase.appendingPathComponent("/upload").appendingPathComponent("/"), prepared: prepared)
        }
        try checkSuccess(envelope: envelope, customCatalogContext: true)
    }
}

func checkSuccess(envelope: HTTPResponseEnvelope, customCatalogContext: Bool = false) throws {
    if envelope.httpStatus >= AudDErrorCodes.httpClientErrorFloor && envelope.jsonBody == nil {
        throw AudDError.serverError(
            httpStatus: envelope.httpStatus,
            message: "HTTP \(envelope.httpStatus) with non-JSON response body",
            requestID: envelope.requestID,
            rawText: envelope.rawText
        )
    }
    guard let body = envelope.jsonBody else {
        throw AudDError.serializationError(message: "Unparseable response", rawText: envelope.rawText)
    }
    if let status = body["status"] as? String {
        if status == "error" {
            throw makeAPIError(from: body, httpStatus: envelope.httpStatus, requestID: envelope.requestID, customCatalogContext: customCatalogContext)
        }
        if status == "success" {
            return
        }
    }
    throw AudDError.serverError(
        httpStatus: envelope.httpStatus,
        message: "Unexpected response status",
        requestID: envelope.requestID,
        rawText: envelope.rawText
    )
}
