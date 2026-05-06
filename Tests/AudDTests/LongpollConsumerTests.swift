// Tokenless LongpollConsumer tests. Spec §6.7 hardening:
// * HTTP non-2xx → AudDError.serverError (not silent loop forever)
// * JSON decode failure on 2xx → AudDError.serializationError
// * READ-class retries on 5xx + connection errors
import XCTest
@testable import AudD

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class LongpollConsumerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testIterateYieldsParsedJSONObject() async throws {
        let session = mockSession()
        let body = try fixtureData("longpoll_no_events.json")
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: body), body)
        }
        let consumer = LongpollConsumer(category: "abc123def", urlSession: session, maxRetries: 1)
        var iterator = consumer.iterate(timeout: 1).makeAsyncIterator()
        guard let event = try await iterator.next() else {
            XCTFail("no event"); return
        }
        XCTAssertEqual(event["timeout"]?.value as? String, "no events before timeout")
        consumer.close()
    }

    func testIterateThrowsOnHTTP500() async throws {
        let session = mockSession()
        MockURLProtocol.register { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, "Internal Server Error".data(using: .utf8)!)
        }
        let consumer = LongpollConsumer(category: "abc123def", urlSession: session, maxRetries: 1, backoffFactor: 0.001)
        var iterator = consumer.iterate(timeout: 1).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("expected error")
        } catch AudDError.serverError(let status, _, _, _) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("unexpected: \(error)")
        }
        consumer.close()
    }

    func testIterateThrowsSerializationOn2xxBadJSON() async throws {
        let session = mockSession()
        let payload = "not json".data(using: .utf8)!
        MockURLProtocol.register { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            return (response, payload)
        }
        let consumer = LongpollConsumer(category: "abc123def", urlSession: session, maxRetries: 1)
        var iterator = consumer.iterate(timeout: 1).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("expected serialization error")
        } catch AudDError.serializationError {
            // ok
        } catch {
            XCTFail("unexpected: \(error)")
        }
        consumer.close()
    }
}
