// Coverage for the `onEvent` inspection hook on `AudD`.
//
// `AudDEvent` lifecycle: `.request` → `.response` (or `.exception`). The hook
// must never carry the api_token, must not break the request path on its own
// failures, and must report errorCode for typed API errors.
import XCTest
@testable import AudD

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class EventHookTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        unsetenv("AUDD_API_TOKEN")
    }

    override func tearDown() {
        unsetenv("AUDD_API_TOKEN")
        super.tearDown()
    }

    func testOnEventEmitsRequestAndResponse() async throws {
        let session = mockSession()
        let payload = "{\"status\":\"success\",\"result\":null}".data(using: .utf8)!
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let collector = EventCollector()
        let audd = try AudD(
            apiToken: "test",
            urlSession: session,
            onEvent: { event in collector.append(event) }
        )
        _ = try await audd.recognize("https://audd.tech/example.mp3")
        let events = collector.snapshot()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].kind, .request)
        XCTAssertEqual(events[0].method, "recognize")
        XCTAssertNil(events[0].elapsed)
        XCTAssertNil(events[0].httpStatus)
        XCTAssertEqual(events[1].kind, .response)
        XCTAssertEqual(events[1].method, "recognize")
        XCTAssertEqual(events[1].httpStatus, 200)
        XCTAssertNotNil(events[1].elapsed)
        await audd.close()
    }

    func testOnEventEmitsExceptionOnAPIError() async throws {
        let session = mockSession()
        let payload = try fixtureData("error_900_invalid_token.json")
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let collector = EventCollector()
        let audd = try AudD(
            apiToken: "test",
            urlSession: session,
            onEvent: { event in collector.append(event) }
        )
        do {
            _ = try await audd.recognize("https://audd.tech/example.mp3")
            XCTFail("expected api error")
        } catch AudDError.api {
            // expected
        }
        let events = collector.snapshot()
        // request, response, then exception once decoding raises typed error.
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].kind, .request)
        XCTAssertEqual(events[1].kind, .response)
        XCTAssertEqual(events[2].kind, .exception)
        XCTAssertEqual(events[2].errorCode, 900)
        await audd.close()
    }

    func testOnEventNeverIncludesApiToken() async throws {
        let session = mockSession()
        let payload = "{\"status\":\"success\",\"result\":null}".data(using: .utf8)!
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let collector = EventCollector()
        let audd = try AudD(
            apiToken: "secret-token-12345",
            urlSession: session,
            onEvent: { event in collector.append(event) }
        )
        _ = try await audd.recognize("https://audd.tech/example.mp3")
        for ev in collector.snapshot() {
            XCTAssertFalse(ev.url.contains("secret-token-12345"), "URL must not include token")
            for (key, value) in ev.extras {
                XCTAssertFalse(key.contains("secret-token-12345"))
                XCTAssertFalse(String(describing: value.value).contains("secret-token-12345"))
            }
        }
        await audd.close()
    }

    func testOnEventHookCalledForBothPhasesWithSameMethodName() async throws {
        let session = mockSession()
        let payload = "{\"status\":\"success\",\"result\":null}".data(using: .utf8)!
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let collector = EventCollector()
        let audd = try AudD(
            apiToken: "test",
            urlSession: session,
            onEvent: { event in
                // Hooks doing arbitrary work — confirm no crash, no broken request.
                collector.append(event)
                _ = (1...10).map { $0 * 2 }
            }
        )
        let result = try await audd.recognize("https://audd.tech/example.mp3")
        XCTAssertNil(result)
        let events = collector.snapshot()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map { $0.method }), ["recognize"])
        await audd.close()
    }

    func testAudDEventStructDefaults() {
        let e = AudDEvent(kind: .request, method: "x", url: "https://example.com/")
        XCTAssertEqual(e.kind, .request)
        XCTAssertEqual(e.method, "x")
        XCTAssertNil(e.requestId)
        XCTAssertNil(e.httpStatus)
        XCTAssertNil(e.elapsed)
        XCTAssertNil(e.errorCode)
        XCTAssertTrue(e.extras.isEmpty)
    }
}

// MARK: - Test helper

final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AudDEvent] = []
    func append(_ e: AudDEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(e)
    }
    func snapshot() -> [AudDEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}
