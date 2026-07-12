// Advanced namespace — lyrics search + raw-request escape hatch.
//
// Reach this only via `audd.advanced.*` — deliberately not on the main client.
// Per spec C2: Advanced uses RECOGNITION retry policy (find_lyrics is metered
// and must not double-bill on read-timeout-after-upload).
// `@preconcurrency import` for Foundation/FoundationNetworking — see AudD.swift
// for the rationale (URL/URLSession Sendable gap on Linux/Swift 5.10).
@preconcurrency import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Advanced: Sendable {
    let http: HTTPClient
    let apiBase: URL
    let recognitionPolicy: RetryPolicy

    init(http: HTTPClient, apiBase: URL, recognitionPolicy: RetryPolicy) {
        self.http = http
        self.apiBase = apiBase
        self.recognitionPolicy = recognitionPolicy
    }

    /// Search lyrics on the AudD lyrics endpoint.
    public func findLyrics(_ query: String) async throws -> [LyricsResult] {
        let body = try await rawRequest(method: "findLyrics", params: ["q": query])
        if let status = body["status"] as? String, status == "error" {
            throw makeAPIError(from: body, httpStatus: 200, requestID: nil)
        }
        guard let resultRaw = body["result"] else { return [] }
        if resultRaw is NSNull { return [] }
        guard let arr = resultRaw as? [[String: Any]] else { return [] }
        return try arr.map { try decode(LyricsResult.self, from: $0) }
    }

    /// Hit any AudD endpoint by method name and return the raw JSON dict.
    /// Useful for endpoints not yet wrapped by typed methods.
    public func rawRequest(method: String, params: [String: String] = [:]) async throws -> [String: Any] {
        let envelope = try await runWithRetry(policy: recognitionPolicy) {
            return try await http.postURLEncoded(url: apiBase.appendingPathComponent(method).appendingPathComponent("/"), fields: params)
        }
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
        return body
    }
}
