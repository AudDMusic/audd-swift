// HTTP transport. URLSession-based; no third-party deps (spec). Uses
// async/await throughout. Multipart bodies are built in-memory because:
// * URLSession's multipart upload from a stream requires Content-Length up-front
//   and is awkward to compose portably (especially on Linux).
// * Source `.file` is read into memory anyway by `prepareSource` so that a
//   retry can re-issue the body. So we already have bytes; just frame them.
//
// HTTPClient lifetime: the `URLSession` is owned by the client (constructed once)
// and invalidated on `close()`/deinit. Users may inject a custom `URLSession`
// for proxy/mTLS scenarios.
import Foundation

#if canImport(FoundationNetworking)
// Linux's Foundation splits URLSession into FoundationNetworking.
import FoundationNetworking
#endif

struct HTTPRequestTimeouts: Sendable {
    let connect: TimeInterval
    let resource: TimeInterval

    static let standard = HTTPRequestTimeouts(connect: 30.0, resource: 60.0)
    static let enterprise = HTTPRequestTimeouts(connect: 30.0, resource: 3600.0)
    static let longpoll = HTTPRequestTimeouts(connect: 10.0, resource: 120.0)
}

struct HTTPResponseEnvelope: @unchecked Sendable {
    /// Parsed JSON object (top-level dict), or nil if the body wasn't a JSON object.
    let jsonBody: [String: Any]?
    let httpStatus: Int
    let requestID: String?
    let rawText: String

    static func parse(data: Data, response: URLResponse) -> HTTPResponseEnvelope {
        let httpResponse = response as? HTTPURLResponse
        let status = httpResponse?.statusCode ?? 0
        let raw = String(data: data, encoding: .utf8) ?? ""
        var requestID: String?
        if let headers = httpResponse?.allHeaderFields {
            for (k, v) in headers {
                if let key = k as? String, key.lowercased() == "x-request-id" {
                    requestID = v as? String
                    break
                }
            }
        }
        let bodyJSON: [String: Any]?
        if let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] {
            bodyJSON = parsed
        } else {
            bodyJSON = nil
        }
        return HTTPResponseEnvelope(jsonBody: bodyJSON, httpStatus: status, requestID: requestID, rawText: raw)
    }
}

final class HTTPClient: @unchecked Sendable {
    private var _apiToken: String
    private let tokenLock = NSLock()
    private let session: URLSession
    private let timeouts: HTTPRequestTimeouts
    private let ownsSession: Bool

    init(apiToken: String, timeouts: HTTPRequestTimeouts = .standard, urlSession: URLSession? = nil) {
        self._apiToken = apiToken
        self.timeouts = timeouts
        if let urlSession {
            self.session = urlSession
            self.ownsSession = false
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = timeouts.connect
            config.timeoutIntervalForResource = timeouts.resource
            self.session = URLSession(configuration: config)
            self.ownsSession = true
        }
    }

    /// Snapshot the current token for use in a single request. Holding the
    /// lock only across the read keeps `setApiToken` non-blocking for callers.
    private var apiToken: String {
        tokenLock.lock(); defer { tokenLock.unlock() }
        return _apiToken
    }

    /// Update the api_token used for subsequent requests. In-flight requests
    /// continue with whatever token they snapshotted. Spec §7.10.
    func setApiToken(_ newToken: String) {
        tokenLock.lock(); defer { tokenLock.unlock() }
        _apiToken = newToken
    }

    func close() {
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
    }

    deinit {
        close()
    }

    /// POST `multipart/form-data`. `prepared.formFields` always becomes form text
    /// fields; we add `api_token` automatically. `prepared.filePart` (if present)
    /// becomes the `file` part.
    func postForm(url: URL, prepared: PreparedRequest) async throws -> HTTPResponseEnvelope {
        let boundary = "----AudDSwiftBoundary-\(UUID().uuidString)"
        var fields = prepared.formFields
        fields["api_token"] = apiToken
        let body = makeMultipartBody(fields: fields, filePart: prepared.filePart, boundary: boundary)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(UserAgent.string(), forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        request.timeoutInterval = timeouts.resource

        let (data, response) = try await dataTask(request: request)
        return HTTPResponseEnvelope.parse(data: data, response: response)
    }

    /// POST `application/x-www-form-urlencoded`. Used for streams management.
    func postURLEncoded(url: URL, fields: [String: String]) async throws -> HTTPResponseEnvelope {
        var allFields = fields
        allFields["api_token"] = apiToken
        let body = urlEncodedBody(fields: allFields)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(UserAgent.string(), forHTTPHeaderField: "User-Agent")
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = timeouts.resource

        let (data, response) = try await dataTask(request: request)
        return HTTPResponseEnvelope.parse(data: data, response: response)
    }

    /// GET. Used for longpoll.
    func get(url: URL, params: [String: String], includeAPIToken: Bool = true) async throws -> HTTPResponseEnvelope {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var allParams = params
        if includeAPIToken {
            allParams["api_token"] = apiToken
        }
        components.queryItems = allParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        let finalURL = components.url ?? url

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.setValue(UserAgent.string(), forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeouts.resource

        let (data, response) = try await dataTask(request: request)
        return HTTPResponseEnvelope.parse(data: data, response: response)
    }

    private func dataTask(request: URLRequest) async throws -> (Data, URLResponse) {
        // Linux Foundation through Swift 5.10 lacks the throwing async URLSession.data(for:).
        // Bridge to a continuation manually for portability.
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
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}

// MARK: - Body building

func makeMultipartBody(fields: [String: String], filePart: FilePart?, boundary: String) -> Data {
    var data = Data()
    let crlf = "\r\n"
    for (key, value) in fields {
        data.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(key)\"\(crlf)\(crlf)".data(using: .utf8)!)
        data.append(value.data(using: .utf8)!)
        data.append(crlf.data(using: .utf8)!)
    }
    if let filePart {
        data.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        let disposition = "Content-Disposition: form-data; name=\"file\"; filename=\"\(filePart.name)\"\(crlf)"
        data.append(disposition.data(using: .utf8)!)
        data.append("Content-Type: \(filePart.mime)\(crlf)\(crlf)".data(using: .utf8)!)
        data.append(filePart.data)
        data.append(crlf.data(using: .utf8)!)
    }
    data.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
    return data
}

func urlEncodedBody(fields: [String: String]) -> String {
    var components = URLComponents()
    components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
    return components.percentEncodedQuery ?? ""
}
