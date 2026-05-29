// Tokenless LongpollConsumer tests. Spec §6.7 hardening:
// * HTTP non-2xx → emits AudDError.serverError on the LongpollPoll's `errors` stream
// * JSON decode failure on 2xx → emits AudDError.serializationError on `errors`
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

    func testIterateBenignNoEventsContinues() async throws {
        // The "no events before timeout" envelope is a benign tick — no match,
        // no notification, no error. The loop continues. We close the poll
        // ourselves to terminate.
        let session = mockSession()
        let body = try fixtureData("longpoll_no_events.json")
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: body), body)
        }
        let consumer = LongpollConsumer(category: "abc123def", urlSession: session, maxRetries: 1)
        let poll = consumer.iterate(options: LongpollOptions(timeout: 1))

        // Give the loop a few ticks, then close.
        try await Task.sleep(nanoseconds: 100_000_000)
        await poll.close()

        // Drain to confirm everything closed cleanly.
        var matchCount = 0
        for await _ in poll.matches { matchCount += 1 }
        XCTAssertEqual(matchCount, 0)

        var notifCount = 0
        for await _ in poll.notifications { notifCount += 1 }
        XCTAssertEqual(notifCount, 0)

        consumer.close()
    }

    func testIterateEmitsServerErrorOnHTTP500() async throws {
        let session = mockSession()
        MockURLProtocol.register { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, "Internal Server Error".data(using: .utf8)!)
        }
        let consumer = LongpollConsumer(category: "abc123def", urlSession: session, maxRetries: 1, backoffFactor: 0.001)
        let poll = consumer.iterate(options: LongpollOptions(timeout: 1))

        // First terminal error must be AudDError.serverError(status: 500).
        var iterator = poll.errors.makeAsyncIterator()
        guard let err = await iterator.next() else {
            XCTFail("no error received"); return
        }
        if case AudDError.serverError(let status, _, _, _) = err {
            XCTAssertEqual(status, 500)
        } else {
            XCTFail("unexpected error: \(err)")
        }
        await poll.close()
        consumer.close()
    }

    func testIterateEmitsSerializationErrorOn2xxBadJSON() async throws {
        let session = mockSession()
        let payload = "not json".data(using: .utf8)!
        MockURLProtocol.register { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            return (response, payload)
        }
        let consumer = LongpollConsumer(category: "abc123def", urlSession: session, maxRetries: 1)
        let poll = consumer.iterate(options: LongpollOptions(timeout: 1))

        var iterator = poll.errors.makeAsyncIterator()
        guard let err = await iterator.next() else {
            XCTFail("no error received"); return
        }
        if case AudDError.serializationError = err {
            // ok
        } else {
            XCTFail("unexpected error: \(err)")
        }
        await poll.close()
        consumer.close()
    }

    func testIterateYieldsMatch() async throws {
        let session = mockSession()
        let body: [String: Any] = [
            "result": [
                "radio_id": 7,
                "timestamp": "2020-04-13 10:31:43",
                "play_length": 111,
                "results": [
                    ["artist": "Alan Walker, A$AP Rocky", "title": "Live Fast (PUBGM)", "score": 100],
                ],
            ],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let consumer = LongpollConsumer(category: "abc123def", urlSession: session, maxRetries: 1)
        let poll = consumer.iterate(options: LongpollOptions(timeout: 1))

        var iterator = poll.matches.makeAsyncIterator()
        guard let match = await iterator.next() else {
            XCTFail("no match received"); return
        }
        XCTAssertEqual(match.song?.artist, "Alan Walker, A$AP Rocky")
        XCTAssertEqual(match.song?.title, "Live Fast (PUBGM)")

        await poll.close()
        consumer.close()
    }
}
