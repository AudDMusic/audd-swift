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
    /// The server holds a longpoll request open for up to 120 seconds, so the
    /// session's idle and resource limits leave room for the longest hold plus
    /// ``longpollRequestMargin``. Each request also sets its own
    /// `timeoutInterval` from the poll's `timeout`.
    static let longpoll = HTTPRequestTimeouts(connect: 135.0, resource: 150.0)
}

/// Seconds a longpoll request waits beyond the poll's own `timeout` before the
/// SDK gives up on it.
let longpollRequestMargin: TimeInterval = 15.0

/// The `timeoutInterval` for one longpoll request that asks the server to hold
/// it for `timeout` seconds.
func longpollRequestTimeout(_ timeout: Int) -> TimeInterval {
    return TimeInterval(max(timeout, 0)) + longpollRequestMargin
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
    private let session: ManagedSession
    private let timeouts: HTTPRequestTimeouts
    /// `close()` cancels requests still running instead of letting them finish.
    private let cancelsOnClose: Bool

    init(
        apiToken: String,
        timeouts: HTTPRequestTimeouts = .standard,
        urlSession: URLSession? = nil,
        cancelsOnClose: Bool = false
    ) {
        self._apiToken = apiToken
        self.timeouts = timeouts
        self.session = ManagedSession(urlSession: urlSession, timeouts: timeouts)
        self.cancelsOnClose = cancelsOnClose
    }

    /// Snapshot the current token for use in a single request. Holding the
    /// lock only across the read keeps `setApiToken` non-blocking for callers.
    var apiToken: String {
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
        session.close(cancelRunning: cancelsOnClose)
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

    /// GET without the api_token. Used for longpoll, which the category alone
    /// authorizes, so the token never appears in the URL.
    func get(url: URL, params: [String: String], timeout: TimeInterval) async throws -> HTTPResponseEnvelope {
        let request = makeGETRequest(url: url, params: params, timeout: timeout)
        let (data, response) = try await performDataTask(session: session, request: request)
        return HTTPResponseEnvelope.parse(data: data, response: response)
    }

    private func dataTask(request: URLRequest) async throws -> (Data, URLResponse) {
        return try await performDataTask(session: session, request: request)
    }
}

extension HTTPClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "HTTPClient(api_token: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["apiToken": "<redacted>"], displayStyle: .class)
    }
}

/// Build a GET request with `params` in the query string and an explicit
/// `timeoutInterval`.
func makeGETRequest(url: URL, params: [String: String], timeout: TimeInterval) -> URLRequest {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = params
        .sorted { $0.key < $1.key }
        .map { URLQueryItem(name: $0.key, value: $0.value) }
    let finalURL = components.url ?? url

    var request = URLRequest(url: finalURL)
    request.httpMethod = "GET"
    request.setValue(UserAgent.string(), forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = timeout
    return request
}

/// A `URLSession` plus whether the SDK created it. A session the SDK created
/// is invalidated on `close()`, after which it refuses new requests (Foundation
/// traps on a task created in an invalidated session).
final class ManagedSession: @unchecked Sendable {
    let session: URLSession
    private let ownsSession: Bool
    private let lock = NSLock()
    private var closed = false

    init(urlSession: URLSession?, timeouts: HTTPRequestTimeouts) {
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

    /// A data task, or `nil` once an SDK-owned session has been closed.
    func makeDataTask(
        with request: URLRequest,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTask? {
        lock.lock(); defer { lock.unlock() }
        if closed && ownsSession { return nil }
        return session.dataTask(with: request, completionHandler: completionHandler)
    }

    /// Invalidate an SDK-owned session. `cancelRunning` cancels requests that
    /// are still running; otherwise they finish first. Idempotent. A session
    /// the caller injected is left as it is.
    func close(cancelRunning: Bool) {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed, ownsSession else { return }
        if cancelRunning {
            session.invalidateAndCancel()
        } else {
            session.finishTasksAndInvalidate()
        }
    }

    deinit {
        close(cancelRunning: false)
    }
}

/// Thrown for a request on a client whose session was closed.
struct ClientClosedError: LocalizedError {
    var errorDescription: String? {
        "This client was closed; create a new one to send more requests."
    }
}

/// Run one `URLSessionDataTask` and wait for it. Cancelling the calling Swift
/// task cancels the data task and throws `CancellationError`.
///
/// Linux Foundation through Swift 5.10 lacks the throwing async
/// `URLSession.data(for:)`, so the completion-handler API is bridged here.
func performDataTask(session: ManagedSession, request: URLRequest) async throws -> (Data, URLResponse) {
    try Task.checkCancellation()
    let handle = DataTaskHandle()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            let made = session.makeDataTask(with: request) { data, response, error in
                if let error {
                    if handle.isCancelled, (error as? URLError)?.code == .cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            guard let task = made else {
                continuation.resume(throwing: ClientClosedError())
                return
            }
            handle.start(task)
        }
    } onCancel: {
        handle.cancel()
    }
}

/// Connects a Swift task's cancellation to the `URLSessionDataTask` it waits on.
private final class DataTaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Resume `task`, or cancel it at once when cancellation arrived first.
    func start(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let alreadyCancelled = cancelled
        lock.unlock()
        task.resume()
        if alreadyCancelled {
            task.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
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

/// `application/x-www-form-urlencoded` body. Every byte outside the RFC 3986
/// unreserved set is percent-encoded, so `+`, `&` and `=` inside a value (a
/// signed callback URL, say) reach the server unchanged.
func urlEncodedBody(fields: [String: String]) -> String {
    return fields
        .sorted { $0.key < $1.key }
        .map { "\(formURLEncode($0.key))=\(formURLEncode($0.value))" }
        .joined(separator: "&")
}

func formURLEncode(_ value: String) -> String {
    var encoded = ""
    for byte in value.utf8 {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            encoded.unicodeScalars.append(Unicode.Scalar(byte))
        default:
            encoded += String(format: "%%%02X", byte)
        }
    }
    return encoded
}
