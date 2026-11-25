// Longpoll tests.
//
// `LongpollLoopTests` drive `LongpollPoll` with a scripted fetch, so each
// server response and each request's parameters can be checked without
// timing. `LongpollConsumerTests` go through URLSession with a mock protocol:
// request counts, the absence of the api_token, retries and cancellation.
import XCTest
@testable import AudD

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Helpers

/// Serves canned longpoll responses in order and records each request. Once
/// the script runs out, a request waits until the poll is closed.
final class ScriptedLongpollServer: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<HTTPResponseEnvelope, Error>]
    private var recorded: [[String: String]] = []
    private var recordedTimeouts: [TimeInterval] = []

    init(_ script: [Result<HTTPResponseEnvelope, Error>]) {
        self.script = script
    }

    convenience init(bodies: [Data]) {
        self.init(bodies.map { .success(longpollEnvelope($0)) })
    }

    var requests: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var requestTimeouts: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return recordedTimeouts
    }

    var fetch: LongpollFetch {
        return { params, timeout in try await self.respond(params, timeout) }
    }

    private func respond(_ params: [String: String], _ timeout: TimeInterval) async throws -> HTTPResponseEnvelope {
        lock.lock()
        recorded.append(params)
        recordedTimeouts.append(timeout)
        let next = script.isEmpty ? nil : script.removeFirst()
        lock.unlock()
        if let next {
            return try next.get()
        }
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }
}

/// Records the pauses the loop asks for without waiting them out.
final class RecordedSleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    var delays: [Double] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var sleep: LongpollSleep {
        return { seconds in
            self.lock.lock()
            self.recorded.append(seconds)
            self.lock.unlock()
            try Task.checkCancellation()
        }
    }
}

func longpollEnvelope(_ body: Data, status: Int = 200) -> HTTPResponseEnvelope {
    let response = HTTPURLResponse(
        url: URL(string: "https://api.audd.io/longpoll/")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return HTTPResponseEnvelope.parse(data: body, response: response)
}

func jsonData(_ object: Any) throws -> Data {
    return try JSONSerialization.data(withJSONObject: object)
}

/// Poll `condition` every 10 ms until it holds or `seconds` pass.
func waitUntil(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// Close `poll` after `seconds`, so a test that is waiting on a stream
/// finishes even when the expected item never arrives.
func watchdog(_ poll: LongpollPoll, seconds: Double = 5) -> Task<Void, Never> {
    return Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await poll.close()
    }
}

/// The first `count` items of `stream`, fewer if it finishes first.
func firstItems<T>(_ stream: AsyncStream<T>, _ count: Int) async -> [T] {
    var items: [T] = []
    var iterator = stream.makeAsyncIterator()
    while items.count < count, let item = await iterator.next() {
        items.append(item)
    }
    return items
}

private func oldShapeBody(timestamp: Int? = nil) -> [String: Any] {
    var body: [String: Any] = [
        "result": [
            "radio_id": 7,
            "timestamp": "2020-04-13 10:31:43",
            "play_length": 111,
            "results": [
                ["artist": "Alan Walker, A$AP Rocky", "title": "Live Fast (PUBGM)", "score": 100],
            ],
        ],
    ]
    if let timestamp { body["timestamp"] = timestamp }
    return body
}

// MARK: - Loop behaviour

final class LongpollLoopTests: XCTestCase {
    func testEventsFixtureDeliversSongsInOrderAndAdvancesSinceTime() async throws {
        let server = ScriptedLongpollServer(bodies: [try fixtureData("longpoll_events.json")])
        let poll = LongpollPoll(category: "92b1cc7f0", options: LongpollOptions(), fetch: server.fetch)
        let guardTask = watchdog(poll)

        let matches = await firstItems(poll.matches, 2)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.first?.song?.artist, "Alan Walker, A$AP Rocky")
        XCTAssertEqual(matches.first?.song?.title, "Live Fast (PUBGM)")
        XCTAssertEqual(matches.first?.radioID, 7)
        XCTAssertEqual(matches.last?.song?.artist, "Tears For Fears")
        XCTAssertEqual(matches.last?.song?.title, "Everybody Wants To Rule The World")
        XCTAssertEqual(matches.last?.radioID, 7)

        let sawNext = await waitUntil { server.requests.count >= 2 }
        XCTAssertTrue(sawNext, "no request after the events response")
        XCTAssertNil(server.requests.first?["since_time"])
        XCTAssertEqual(server.requests.last?["since_time"], "1795547548112")
        XCTAssertEqual(server.requests.last?["category"], "92b1cc7f0")

        guardTask.cancel()
        await poll.close()
    }

    func testTimeoutFixtureDeliversNothingAndSendsItsTimestamp() async throws {
        let server = ScriptedLongpollServer(bodies: [try fixtureData("longpoll_no_events.json")])
        let sleeps = RecordedSleeps()
        let poll = LongpollPoll(
            category: "abc123def",
            options: LongpollOptions(sinceTime: 1),
            fetch: server.fetch,
            sleep: sleeps.sleep
        )

        let sawNext = await waitUntil { server.requests.count >= 2 }
        XCTAssertTrue(sawNext)
        XCTAssertEqual(server.requests.first?["since_time"], "1")
        XCTAssertEqual(server.requests.last?["since_time"], "1777901270049")
        // A new timestamp is progress: no pause before the next request.
        XCTAssertEqual(sleeps.delays, [])

        await poll.close()
        let matches = await firstItems(poll.matches, 1)
        let notifications = await firstItems(poll.notifications, 1)
        let errors = await firstItems(poll.errors, 1)
        XCTAssertTrue(matches.isEmpty)
        XCTAssertTrue(notifications.isEmpty)
        XCTAssertTrue(errors.isEmpty)
    }

    func testErrorFixtureEndsSubscriptionAfterOneRequest() async throws {
        let server = ScriptedLongpollServer(bodies: [try fixtureData("longpoll_error.json")])
        let poll = LongpollPoll(category: "abc123def", options: LongpollOptions(timeout: 500), fetch: server.fetch)
        let guardTask = watchdog(poll)

        let errors = await firstItems(poll.errors, 2)
        XCTAssertEqual(errors.count, 1)
        guard case AudDError.api(let detail)? = errors.first else {
            return XCTFail("expected AudDError.api, got \(String(describing: errors.first))")
        }
        XCTAssertEqual(detail.kind, .invalidRequest)
        XCTAssertEqual(detail.message, "Invalid timeout arg.  Must be 1-120.")

        // The matches stream ends too, and nothing else was requested.
        let matches = await firstItems(poll.matches, 1)
        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(server.requests.count, 1)
        guardTask.cancel()
        await poll.close()
    }

    func testStatusErrorBodyEndsSubscriptionWithAPIError() async throws {
        let body = try fixtureData("error_900_invalid_token.json")
        let server = ScriptedLongpollServer(bodies: [body])
        let poll = LongpollPoll(category: "abc123def", options: LongpollOptions(), fetch: server.fetch)
        let guardTask = watchdog(poll)

        let errors = await firstItems(poll.errors, 1)
        guard case AudDError.api(let detail)? = errors.first else {
            return XCTFail("expected AudDError.api, got \(String(describing: errors.first))")
        }
        XCTAssertEqual(detail.errorCode, 900)
        XCTAssertEqual(server.requests.count, 1)
        guardTask.cancel()
        await poll.close()
    }

    func testTopLevelResultShapeStillDelivers() async throws {
        let server = ScriptedLongpollServer(bodies: [try jsonData(oldShapeBody(timestamp: 1700000000123))])
        let poll = LongpollPoll(category: "abc123def", options: LongpollOptions(), fetch: server.fetch)
        let guardTask = watchdog(poll)

        let matches = await firstItems(poll.matches, 1)
        XCTAssertEqual(matches.first?.song?.artist, "Alan Walker, A$AP Rocky")
        XCTAssertEqual(matches.first?.song?.title, "Live Fast (PUBGM)")
        XCTAssertEqual(matches.first?.radioID, 7)

        let sawNext = await waitUntil { server.requests.count >= 2 }
        XCTAssertTrue(sawNext)
        XCTAssertEqual(server.requests.last?["since_time"], "1700000000123")
        guardTask.cancel()
        await poll.close()
    }

    func testTopLevelNotificationShapeStillDelivers() async throws {
        let server = ScriptedLongpollServer(bodies: [try fixtureData("streams_callback_with_notification.json")])
        let poll = LongpollPoll(category: "abc123def", options: LongpollOptions(), fetch: server.fetch)
        let guardTask = watchdog(poll)

        let notifications = await firstItems(poll.notifications, 1)
        XCTAssertEqual(notifications.first?.notificationCode, 650)
        XCTAssertEqual(notifications.first?.radioID, 3)
        guardTask.cancel()
        await poll.close()
    }

    func testEventsSkipEmptyResultsAndUnparseableDataAndDecodeStringData() async throws {
        let songData: [String: Any] = [
            "status": "success",
            "result": ["radio_id": 9, "results": [["artist": "B", "title": "Second"]]],
        ]
        let songText = String(data: try jsonData(songData), encoding: .utf8)!
        let body: [String: Any] = [
            "events": [
                ["timestamp": 10, "category": "c", "data": ["status": "success", "result": ["radio_id": 9, "results": []]]],
                ["timestamp": 20, "category": "c", "data": 42],
                ["timestamp": 30, "category": "c", "data": "not json"],
                ["timestamp": 40, "category": "c", "data": songText],
                ["timestamp": 50, "category": "c", "data": try JSONSerialization.jsonObject(with: fixtureData("streams_callback_with_notification.json"))],
            ],
        ]
        let server = ScriptedLongpollServer(bodies: [try jsonData(body)])
        let poll = LongpollPoll(category: "c", options: LongpollOptions(), fetch: server.fetch)
        let guardTask = watchdog(poll)

        let matches = await firstItems(poll.matches, 1)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.song?.title, "Second")
        XCTAssertEqual(matches.first?.radioID, 9)
        let notifications = await firstItems(poll.notifications, 1)
        XCTAssertEqual(notifications.first?.notificationCode, 650)

        let sawNext = await waitUntil { server.requests.count >= 2 }
        XCTAssertTrue(sawNext, "skipped events must not end the subscription")
        XCTAssertEqual(server.requests.last?["since_time"], "50")
        guardTask.cancel()
        await poll.close()
        let errors = await firstItems(poll.errors, 1)
        XCTAssertTrue(errors.isEmpty)
    }

    func testResponsesWithNothingNewBackOffFromOneToThirtySeconds() async throws {
        let junk = [
            Data("not json".utf8),
            Data(),
            Data("{\"something\":\"else\"}".utf8),
            Data("{\"events\":[]}".utf8),
            Data("[1,2,3]".utf8),
            Data("<html>gateway</html>".utf8),
            Data("{\"timeout\":\"no events before timeout\"}".utf8),
        ]
        let server = ScriptedLongpollServer(bodies: junk)
        let sleeps = RecordedSleeps()
        let poll = LongpollPoll(category: "abc123def", options: LongpollOptions(), fetch: server.fetch, sleep: sleeps.sleep)

        let done = await waitUntil { server.requests.count >= junk.count + 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(sleeps.delays, [1, 2, 4, 8, 16, 30, 30])
        await poll.close()
        let errors = await firstItems(poll.errors, 1)
        XCTAssertTrue(errors.isEmpty, "a body with nothing new is not an error")
    }

    func testBackoffResetsAfterProgress() async throws {
        let junk = Data("not json".utf8)
        let server = ScriptedLongpollServer(bodies: [junk, junk, try fixtureData("longpoll_events.json"), junk])
        let sleeps = RecordedSleeps()
        let poll = LongpollPoll(category: "abc123def", options: LongpollOptions(), fetch: server.fetch, sleep: sleeps.sleep)

        let done = await waitUntil { server.requests.count >= 5 }
        XCTAssertTrue(done)
        XCTAssertEqual(sleeps.delays, [1, 2, 1])
        await poll.close()
    }

    func testRequestTimeoutOutlastsTheServerHold() async throws {
        let server = ScriptedLongpollServer(bodies: [])
        let poll = LongpollPoll(category: "abc123def", options: LongpollOptions(timeout: 120), fetch: server.fetch)
        let started = await waitUntil { server.requests.count >= 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(server.requests.first?["timeout"], "120")
        XCTAssertEqual(server.requestTimeouts.first ?? 0, 135, accuracy: 0.001)
        await poll.close()
    }

    func testFetchFailureReachesErrorsOnce() async throws {
        let failure = AudDError.connection(message: "offline", underlying: URLError(.notConnectedToInternet))
        let server = ScriptedLongpollServer([.failure(failure)])
        let poll = LongpollPoll(category: "abc123def", options: LongpollOptions(), fetch: server.fetch)
        let guardTask = watchdog(poll)

        let errors = await firstItems(poll.errors, 2)
        XCTAssertEqual(errors.count, 1)
        guard case AudDError.connection? = errors.first else {
            return XCTFail("expected AudDError.connection, got \(String(describing: errors.first))")
        }
        XCTAssertEqual(server.requests.count, 1)
        guardTask.cancel()
        await poll.close()
    }

    func testCloseInterruptsTheBackoffWait() async throws {
        let server = ScriptedLongpollServer(bodies: [Data("not json".utf8)])
        let poll = LongpollPoll(category: "abc123def", options: LongpollOptions(), fetch: server.fetch)
        let started = await waitUntil { server.requests.count >= 1 }
        XCTAssertTrue(started)
        // The loop is now waiting 1 s before the next request.
        await poll.close()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(server.requests.count, 1, "no request after close()")
    }
}

// MARK: - Through URLSession

final class LongpollConsumerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        HangingURLProtocol.reset()
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

        let sawSecond = await waitUntil { MockURLProtocol.requestLog.count >= 2 }
        XCTAssertTrue(sawSecond)
        let second = URLComponents(url: MockURLProtocol.requestLog[1].url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(second?.queryItems?.first { $0.name == "since_time" }?.value, "1777901270049")
        await poll.close()

        // Drain to confirm everything closed cleanly.
        let matches = await firstItems(poll.matches, 1)
        XCTAssertTrue(matches.isEmpty)
        let notifications = await firstItems(poll.notifications, 1)
        XCTAssertTrue(notifications.isEmpty)

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

    func testServerErrorIsRetriedThenEventsArrive() async throws {
        let session = mockSession()
        let events = try fixtureData("longpoll_events.json")
        let lock = NSLock()
        var calls = 0
        MockURLProtocol.register { request in
            lock.lock(); calls += 1; let call = calls; lock.unlock()
            if call == 1 {
                let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data("Service Unavailable".utf8))
            }
            if call == 2 {
                return (makeJSONResponse(request.url!, body: events), events)
            }
            throw MockHandlerSkip.skip
        }
        let consumer = LongpollConsumer(category: "92b1cc7f0", urlSession: session, maxRetries: 3, backoffFactor: 0.001)
        let poll = consumer.iterate(options: LongpollOptions(timeout: 1))
        let guardTask = watchdog(poll)

        let matches = await firstItems(poll.matches, 2)
        XCTAssertEqual(matches.map { $0.song?.title }, ["Live Fast (PUBGM)", "Everybody Wants To Rule The World"])
        guardTask.cancel()
        await poll.close()
        consumer.close()
    }

    func testErrorBodyIsSurfacedOnceWithOneRequest() async throws {
        let session = mockSession()
        let body = try fixtureData("longpoll_error.json")
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: body), body)
        }
        let consumer = LongpollConsumer(category: "abc123def", urlSession: session, maxRetries: 3, backoffFactor: 0.001)
        let poll = consumer.iterate(options: LongpollOptions(timeout: 500))
        let guardTask = watchdog(poll)

        let errors = await firstItems(poll.errors, 2)
        XCTAssertEqual(errors.count, 1)
        if case AudDError.api(let detail)? = errors.first {
            XCTAssertEqual(detail.kind, .invalidRequest)
            XCTAssertEqual(detail.message, "Invalid timeout arg.  Must be 1-120.")
        } else {
            XCTFail("unexpected error: \(String(describing: errors.first))")
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(MockURLProtocol.requestLog.count, 1)
        guardTask.cancel()
        await poll.close()
        consumer.close()
    }

    func testJunkBodyDoesNotSpin() async throws {
        // Real backoff: requests at about 0 s, 1 s and 3 s.
        let session = mockSession()
        let payload = Data("not json".utf8)
        MockURLProtocol.register { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            return (response, payload)
        }
        let consumer = LongpollConsumer(category: "abc123def", urlSession: session, maxRetries: 1)
        let poll = consumer.iterate(options: LongpollOptions(timeout: 1))

        try await Task.sleep(nanoseconds: 2_500_000_000)
        let count = MockURLProtocol.requestLog.count
        await poll.close()
        XCTAssertGreaterThanOrEqual(count, 2)
        XCTAssertLessThanOrEqual(count, 4, "junk responses must not be re-requested in a tight loop")
        let errors = await firstItems(poll.errors, 1)
        XCTAssertTrue(errors.isEmpty)
        consumer.close()
    }

    func testIterateYieldsMatch() async throws {
        let session = mockSession()
        let payload = try jsonData(oldShapeBody())
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

    func testRequestCarriesNoTokenAndAnExplicitTimeout() async throws {
        let session = mockSession()
        let body = try fixtureData("longpoll_no_events.json")
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: body), body)
        }
        let consumer = LongpollConsumer(category: "abc123def", urlSession: session)
        let poll = consumer.iterate(options: LongpollOptions(timeout: 30))
        let started = await waitUntil { MockURLProtocol.requestLog.count >= 1 }
        XCTAssertTrue(started)
        await poll.close()

        let request = MockURLProtocol.requestLog[0]
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(Set(items.map(\.name)), ["category", "timeout"])
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 45, accuracy: 0.001)
        XCTAssertNil(request.allHTTPHeaderFields?.keys.first { $0.lowercased().contains("token") })
        consumer.close()
    }

    func testPollCloseCancelsTheWaitingRequest() async throws {
        let consumer = LongpollConsumer(category: "abc123def", urlSession: hangingSession())
        let poll = consumer.iterate(options: LongpollOptions(timeout: 50))

        let started = await waitUntil { HangingURLProtocol.startedCount >= 1 }
        XCTAssertTrue(started)
        await poll.close()
        let stopped = await waitUntil(3) { HangingURLProtocol.stoppedCount >= 1 }
        XCTAssertTrue(stopped, "the request waiting on the server must be cancelled")
        let matches = await firstItems(poll.matches, 1)
        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(HangingURLProtocol.startedCount, 1)
        consumer.close()
    }

    func testConsumerCloseEndsItsPolls() async throws {
        // An SDK-owned session cannot be pointed at a mock, so only check that
        // closing ends the poll quietly and nothing traps afterwards.
        let consumer = LongpollConsumer(category: "abc123def", endpoint: URL(string: "http://127.0.0.1:9/longpoll/")!)
        let poll = consumer.iterate(options: LongpollOptions(timeout: 1))
        consumer.close()
        let started = Date()
        let guardTask = watchdog(poll, seconds: 10)
        let errors = await firstItems(poll.errors, 1)
        guardTask.cancel()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the poll must end when its consumer closes")
        // Either the poll ended quietly, or the connection failure that came
        // first was reported; it never traps on the closed session.
        if let error = errors.first {
            guard case AudDError.connection = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        await poll.close()
    }
}

// MARK: - A protocol that never answers

final class HangingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started = 0
    nonisolated(unsafe) private static var stopped = 0

    static var startedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    static var stoppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        started = 0
        stopped = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self.started += 1; Self.lock.unlock()
    }

    override func stopLoading() {
        Self.lock.lock(); Self.stopped += 1; Self.lock.unlock()
    }
}

func hangingSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HangingURLProtocol.self]
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 60
    return URLSession(configuration: config)
}
