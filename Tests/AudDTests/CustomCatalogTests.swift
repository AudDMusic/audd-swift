// Custom-catalog endpoint tests. Spec §6.4: 904 from custom catalog flips to
// .customCatalogAccess with overridden message.
import XCTest
@testable import AudD

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CustomCatalogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testCustomCatalogAddSuccess() async throws {
        let session = mockSession()
        let body = ["status": "success", "result": NSNull()] as [String: Any]
        let payload = try JSONSerialization.data(withJSONObject: body)
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        try await audd.customCatalog.add(audioID: 1, source: .data("audio".data(using: .utf8)!))
        await audd.close()
    }

    func testCustomCatalogAdd904RaisesCustomAccessKind() async throws {
        let session = mockSession()
        let payload = try fixtureData("error_904_enterprise_unauthorized.json")
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let audd = try AudD(apiToken: "test", maxRetries: 1, urlSession: session)
        do {
            try await audd.customCatalog.add(audioID: 1, source: .data("x".data(using: .utf8)!))
            XCTFail("expected error")
        } catch let AudDError.api(detail) {
            XCTAssertEqual(detail.kind, .customCatalogAccess)
            XCTAssertTrue(detail.message.contains("Adding songs to your custom catalog"))
            // Server message preserved at the bottom for ticket-grepping
            XCTAssertTrue(detail.message.contains("[Server message:"))
        } catch {
            XCTFail("unexpected: \(error)")
        }
        await audd.close()
    }

    /// Custom-catalog upload is metered. A 5xx must surface immediately as a
    /// single attempt, even when the caller configured the SDK with a higher
    /// `maxRetries`. Auto-retry on a metered upload could double-charge for
    /// the same fingerprinting work.
    func testCustomCatalogAdd5xxDoesNotRetry() async throws {
        let session = mockSession()
        let attemptsLock = NSLock()
        var attempts = 0
        MockURLProtocol.register { request in
            attemptsLock.lock()
            attempts += 1
            attemptsLock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, "Service Unavailable".data(using: .utf8)!)
        }
        // Caller asks for 3 retries — the .critical policy must clamp to 1.
        let audd = try AudD(apiToken: "test", maxRetries: 3, backoffFactor: 0.001, urlSession: session)
        do {
            try await audd.customCatalog.add(audioID: 1, source: .data("audio".data(using: .utf8)!))
            XCTFail("expected error")
        } catch AudDError.serverError {
            // expected — 5xx surfaces as a server error after a single attempt
        } catch {
            XCTFail("unexpected: \(error)")
        }
        XCTAssertEqual(attempts, 1, "customCatalog.add must not retry on 5xx (metered upload)")
        await audd.close()
    }

    /// A pre-upload transport failure must also surface as a single attempt.
    /// We don't retry connect errors either: a "failed" attempt may still
    /// count server-side, and a silent re-send is precisely what could
    /// double-charge.
    func testCustomCatalogAddConnectErrorDoesNotRetry() async throws {
        let session = mockSession()
        let attemptsLock = NSLock()
        var attempts = 0
        MockURLProtocol.register { request in
            attemptsLock.lock()
            attempts += 1
            attemptsLock.unlock()
            // URLError.cannotConnectToHost — would be retry-eligible under
            // .recognition / .mutating, must NOT be retried under .critical.
            throw URLError(.cannotConnectToHost)
        }
        let audd = try AudD(apiToken: "test", maxRetries: 3, backoffFactor: 0.001, urlSession: session)
        do {
            try await audd.customCatalog.add(audioID: 1, source: .data("audio".data(using: .utf8)!))
            XCTFail("expected error")
        } catch AudDError.connection {
            // expected — pre-upload connect failure surfaces after a single attempt
        } catch {
            XCTFail("unexpected: \(error)")
        }
        XCTAssertEqual(attempts, 1, "customCatalog.add must not retry on transport failure (metered upload)")
        await audd.close()
    }
}
