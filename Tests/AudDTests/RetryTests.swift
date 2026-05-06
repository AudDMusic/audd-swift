// Retry policy unit tests.
import XCTest
@testable import AudD

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RetryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testStatusRetryEligibility() {
        // READ retries 408, 429, 500
        XCTAssertTrue(shouldRetryStatus(408, retryClass: .read))
        XCTAssertTrue(shouldRetryStatus(429, retryClass: .read))
        XCTAssertTrue(shouldRetryStatus(503, retryClass: .read))
        XCTAssertFalse(shouldRetryStatus(404, retryClass: .read))
        // RECOGNITION retries only 5xx
        XCTAssertTrue(shouldRetryStatus(503, retryClass: .recognition))
        XCTAssertFalse(shouldRetryStatus(429, retryClass: .recognition))
        XCTAssertFalse(shouldRetryStatus(408, retryClass: .recognition))
        // MUTATING retries nothing on status (side effects may have happened)
        XCTAssertFalse(shouldRetryStatus(503, retryClass: .mutating))
        XCTAssertFalse(shouldRetryStatus(429, retryClass: .mutating))
    }

    func testRecognitionRetriesOn5xxThenSucceeds() async throws {
        let session = mockSession()
        let goodBody = try fixtureData("recognize_basic.json")
        var attempts = 0
        let attemptsLock = NSLock()
        MockURLProtocol.register { request in
            attemptsLock.lock()
            attempts += 1
            let attempt = attempts
            attemptsLock.unlock()
            if attempt == 1 {
                let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, "Service Unavailable".data(using: .utf8)!)
            }
            return (makeJSONResponse(request.url!, body: goodBody), goodBody)
        }
        let audd = try AudD(apiToken: "test", maxRetries: 3, backoffFactor: 0.001, urlSession: session)
        let result = try await audd.recognize("https://audd.tech/example.mp3")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(result?.artist, "Tears For Fears")
        await audd.close()
    }
}
