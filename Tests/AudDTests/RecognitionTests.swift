// Recognition flow tests. Mock the URLSession via MockURLProtocol.
import XCTest
@testable import AudD

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RecognitionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testRecognizeURLBasic() async throws {
        let session = mockSession()
        let payload = try fixtureData("recognize_basic.json")
        MockURLProtocol.register { request in
            let response = makeJSONResponse(request.url!, body: payload)
            return (response, payload)
        }
        let audd = try AudD(
            apiToken: "test",
            urlSession: session,
            apiBase: URL(string: "https://api.audd.io")!
        )
        let result = try await audd.recognize("https://audd.tech/example.mp3")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.artist, "Tears For Fears")
        XCTAssertEqual(result?.title, "Everybody Wants To Rule The World")
        XCTAssertEqual(result?.timecode, "00:56")
        XCTAssertTrue(result?.isPublicMatch ?? false)
        XCTAssertFalse(result?.isCustomMatch ?? false)
        XCTAssertEqual(result?.thumbnailURL, "https://lis.tn/NbkVb?thumb")
        await audd.close()
    }

    func testRecognizeNoMatch() async throws {
        let session = mockSession()
        let payload = "{\"status\":\"success\",\"result\":null}".data(using: .utf8)!
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        let result = try await audd.recognize("https://audd.tech/example.mp3")
        XCTAssertNil(result)
        await audd.close()
    }

    func testRecognizeCustomMatch() async throws {
        let session = mockSession()
        let payload = try fixtureData("recognize_custom_match.json")
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        let result = try await audd.recognize("https://audd.tech/example.mp3")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.audioID, 146)
        XCTAssertEqual(result?.timecode, "01:45")
        XCTAssertTrue(result?.isCustomMatch ?? false)
        XCTAssertFalse(result?.isPublicMatch ?? false)
        XCTAssertNil(result?.thumbnailURL)
        await audd.close()
    }

    func testRecognizeWithMetadataExposesExtras() async throws {
        let session = mockSession()
        let payload = try fixtureData("recognize_with_metadata.json")
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        let result = try await audd.recognize("https://audd.tech/example.mp3")
        XCTAssertNotNil(result)
        // Apple Music metadata is typed
        XCTAssertEqual(result?.appleMusic?.artistName, "Tears for Fears")
        XCTAssertEqual(result?.appleMusic?.isrc, "GBUM71403885")
        // Forward-compat: server returns "previews" / "artwork" / etc that aren't typed —
        // they should round-trip via extras.
        XCTAssertNotNil(result?.appleMusic?.extras["previews"])
        XCTAssertNotNil(result?.appleMusic?.extras["artwork"])
        // Top-level rawResponse is the full payload.
        XCTAssertNotNil(result?.rawResponse)
        await audd.close()
    }

    func testAuthenticationErrorTypedAndKindCorrect() async throws {
        let session = mockSession()
        let payload = try fixtureData("error_900_invalid_token.json")
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        do {
            _ = try await audd.recognize("https://audd.tech/example.mp3")
            XCTFail("expected auth error")
        } catch let AudDError.api(detail) {
            XCTAssertEqual(detail.errorCode, 900)
            XCTAssertEqual(detail.kind, .authentication)
            XCTAssertTrue(detail.message.contains("authorization failed"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        await audd.close()
    }

    func testServerErrorOnNon2xxNonJSON() async throws {
        // Spec S2: HTTP non-2xx + non-JSON → AudDError.serverError, NOT serializationError.
        let session = mockSession()
        let payload = "<html><body>Bad Gateway</body></html>".data(using: .utf8)!
        MockURLProtocol.register { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
            return (response, payload)
        }
        let audd = try AudD(apiToken: "test", maxRetries: 1, urlSession: session)
        do {
            _ = try await audd.recognize("https://audd.tech/example.mp3")
            XCTFail("expected server error")
        } catch AudDError.serverError(let status, _, _, _) {
            XCTAssertEqual(status, 502)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        await audd.close()
    }

    func testSerializationErrorOn2xxBadJSON() async throws {
        // Spec S2: 2xx + bad JSON → AudDError.serializationError.
        let session = mockSession()
        let payload = "definitely not json".data(using: .utf8)!
        MockURLProtocol.register { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            return (response, payload)
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        do {
            _ = try await audd.recognize("https://audd.tech/example.mp3")
            XCTFail("expected serialization error")
        } catch AudDError.serializationError {
            // ok
        } catch {
            XCTFail("unexpected error \(error)")
        }
        await audd.close()
    }

    func testCode51DeprecationPassThrough() async throws {
        // Spec C3: code 51 + usable result → emit warning, return result.
        let session = mockSession()
        let body: [String: Any] = [
            "status": "error",
            "error": ["error_code": 51, "error_message": "deprecated parameter X"],
            "result": ["timecode": "00:30", "artist": "X", "title": "Y"],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        let result = try await audd.recognize("https://audd.tech/example.mp3")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.artist, "X")
        await audd.close()
    }

    // MARK: - Enterprise accurate offsets

    /// The chunk `offset` anchors each song's fragment-relative offsets to its
    /// position in the user's file. Chunk "00:01:00" + startOffset 4200ms ⇒
    /// 64.2s; + endOffset 11800ms ⇒ 71.8s. A chunk with no offset ⇒ nil.
    func testEnterpriseStartEndSecondsFromChunkOffset() async throws {
        let session = mockSession()
        let body: [String: Any] = [
            "status": "success",
            "result": [
                [
                    "offset": "00:01:00",
                    "songs": [
                        [
                            "artist": "A", "title": "T",
                            "start_offset": 4200, "end_offset": 11800,
                        ],
                    ],
                ],
                [
                    // No offset on this chunk → seconds remain nil.
                    "songs": [
                        [
                            "artist": "B", "title": "U",
                            "start_offset": 1000, "end_offset": 2000,
                        ],
                    ],
                ],
            ],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        let matches = try await audd.recognizeEnterprise(.url(URL(string: "https://audd.tech/example.mp3")!))
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].startSeconds ?? -1, 64.2, accuracy: 0.0001)
        XCTAssertEqual(matches[0].endSeconds ?? -1, 71.8, accuracy: 0.0001)
        XCTAssertNil(matches[1].startSeconds)
        XCTAssertNil(matches[1].endSeconds)
        await audd.close()
    }

    /// A default `recognizeEnterprise` call sends `accurate_offsets=true`.
    func testEnterpriseDefaultsAccurateOffsetsOn() async throws {
        let session = mockSession()
        let payload = "{\"status\":\"success\",\"result\":[]}".data(using: .utf8)!
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        _ = try await audd.recognizeEnterprise(.url(URL(string: "https://audd.tech/example.mp3")!))
        let enterpriseRequest = MockURLProtocol.requestLog.first {
            $0.url?.host == "enterprise.audd.io"
        }
        let req = try XCTUnwrap(enterpriseRequest, "expected an enterprise request")
        let bodyData = try XCTUnwrap(MockURLProtocol.bodyData(for: req))
        let bodyString = String(decoding: bodyData, as: UTF8.self)
        XCTAssertTrue(
            bodyString.contains("accurate_offsets"),
            "request body should carry accurate_offsets"
        )
        // The value next to the field name must be true.
        if let range = bodyString.range(of: "name=\"accurate_offsets\"") {
            let after = bodyString[range.upperBound...]
            XCTAssertTrue(after.contains("true"), "accurate_offsets should be true")
        }
        await audd.close()
    }
}

func fixtureData(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        ?? Bundle.module.url(forResource: name, withExtension: nil)
    guard let url else {
        throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture not found: \(name)"])
    }
    return try Data(contentsOf: url)
}
