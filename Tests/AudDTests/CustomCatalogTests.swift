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
}
