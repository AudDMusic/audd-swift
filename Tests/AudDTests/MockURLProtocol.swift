// MockURLProtocol — intercept URLSession requests in unit tests.
//
// Register one or more handlers keyed by URL pattern; the protocol returns the
// canned (Data, status, headers) tuple instead of hitting the network.
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data?)

    /// Static handler registry. Tests must call `register(_:)` and `reset()`.
    nonisolated(unsafe) static var handlers: [Handler] = []
    nonisolated(unsafe) static var requestLog: [URLRequest] = []
    private static let lock = NSLock()

    static func register(_ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers.append(handler)
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeAll()
        requestLog.removeAll()
    }

    static func bodyData(for request: URLRequest) -> Data? {
        // Linux URLSession upload tasks store body on httpBodyStream; otherwise httpBody.
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = buffer.withUnsafeMutableBufferPointer { buf -> Int in
                guard let base = buf.baseAddress else { return 0 }
                return stream.read(base, maxLength: buf.count)
            }
            if read <= 0 { break }
            collected.append(buffer, count: read)
        }
        return collected
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handlers = Self.handlers
        Self.requestLog.append(request)
        Self.lock.unlock()

        for handler in handlers {
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if let data {
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
                return
            } catch MockHandlerSkip.skip {
                continue
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        }
        // No handler matched; fail clearly.
        let error = NSError(domain: "MockURLProtocol", code: 1, userInfo: [NSLocalizedDescriptionKey: "No mock handler matched URL: \(request.url?.absoluteString ?? "<nil>")"])
        client?.urlProtocol(self, didFailWithError: error)
    }

    override func stopLoading() {}
}

enum MockHandlerSkip: Error {
    case skip
}

func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    config.timeoutIntervalForRequest = 5.0
    config.timeoutIntervalForResource = 5.0
    return URLSession(configuration: config)
}

func makeJSONResponse(_ url: URL, status: Int = 200, body: Data, headers: [String: String] = [:]) -> HTTPURLResponse {
    var allHeaders = ["Content-Type": "application/json"]
    for (k, v) in headers { allHeaders[k] = v }
    return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: allHeaders)!
}
