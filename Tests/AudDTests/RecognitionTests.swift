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

    // MARK: - Enterprise limit

    func testEnterpriseSendsNoLimitByDefault() async throws {
        let session = mockSession()
        let payload = Data("{\"status\":\"success\",\"result\":[]}".utf8)
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        _ = try await audd.recognizeEnterprise(.data(Data("audio".utf8)))
        let req = try XCTUnwrap(MockURLProtocol.requestLog.first { $0.url?.host == "enterprise.audd.io" })
        let body = String(decoding: try XCTUnwrap(MockURLProtocol.bodyData(for: req)), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"limit\""), "no limit field unless the caller sets one")
        await audd.close()
    }

    func testEnterpriseSendsAnExplicitLimit() async throws {
        let session = mockSession()
        let payload = Data("{\"status\":\"success\",\"result\":[]}".utf8)
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        _ = try await audd.recognizeEnterprise(.data(Data("audio".utf8)), limit: 3)
        let req = try XCTUnwrap(MockURLProtocol.requestLog.first { $0.url?.host == "enterprise.audd.io" })
        let body = String(decoding: try XCTUnwrap(MockURLProtocol.bodyData(for: req)), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"limit\"\r\n\r\n3\r\n"))
        await audd.close()
    }

    // MARK: - String sources

    func testStringSourceClassification() throws {
        guard case .url(let web) = try sourceForString("https://audd.tech/example.mp3") else {
            return XCTFail("https string must be a URL source")
        }
        XCTAssertEqual(web.absoluteString, "https://audd.tech/example.mp3")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("audd-source-\(UUID().uuidString).mp3")
        try Data("audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        guard case .file(let local) = try sourceForString(file.path) else {
            return XCTFail("an existing path must be a file source")
        }
        XCTAssertEqual(local.path, file.path)
        guard case .file = try sourceForString(file.absoluteString) else {
            return XCTFail("a file:// URL must be a file source")
        }

        XCTAssertThrowsError(try sourceForString("/no/such/dir/clip.mp3")) { error in
            guard case AudDError.invalidArgument = error else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
        }
    }

    func testRecognizeLocalPathUploadsTheFile() async throws {
        let session = mockSession()
        let payload = try fixtureData("recognize_basic.json")
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("audd-clip-\(UUID().uuidString).mp3")
        try Data("fake audio bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let audd = try AudD(apiToken: "test", urlSession: session)
        _ = try await audd.recognize(file.path)
        let req = try XCTUnwrap(MockURLProtocol.requestLog.first)
        let body = String(decoding: try XCTUnwrap(MockURLProtocol.bodyData(for: req)), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"\(file.lastPathComponent)\""))
        XCTAssertTrue(body.contains("fake audio bytes"))
        XCTAssertFalse(body.contains("name=\"url\""))
        await audd.close()
    }

    // MARK: - Attempts

    func testMaxRetriesZeroOrNegativeMakesOneAttempt() async throws {
        for maxRetries in [0, -1] {
            MockURLProtocol.reset()
            let session = mockSession()
            let payload = try fixtureData("recognize_basic.json")
            MockURLProtocol.register { request in
                (makeJSONResponse(request.url!, body: payload), payload)
            }
            let audd = try AudD(apiToken: "test", maxRetries: maxRetries, urlSession: session)
            let result = try await audd.recognize("https://audd.tech/example.mp3")
            XCTAssertEqual(result?.artist, "Tears For Fears")
            XCTAssertEqual(MockURLProtocol.requestLog.count, 1)
            await audd.close()
        }
        XCTAssertEqual(RetryPolicy(retryClass: .read, maxAttempts: 0).maxAttempts, 1)
        XCTAssertEqual(RetryPolicy(retryClass: .recognition, maxAttempts: -5).maxAttempts, 1)
    }

    // MARK: - Cancellation

    func testCancellingRecognizeCancelsTheRequest() async throws {
        HangingURLProtocol.reset()
        let audd = try AudD(apiToken: "test", urlSession: hangingSession())
        let started = Date()
        let task = Task { try await audd.recognize("https://audd.tech/example.mp3") }
        let sent = await waitUntil { HangingURLProtocol.startedCount >= 1 }
        XCTAssertTrue(sent)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let stopped = await waitUntil { HangingURLProtocol.stoppedCount >= 1 }
        XCTAssertTrue(stopped)
        XCTAssertEqual(HangingURLProtocol.startedCount, 1, "a cancelled call is not retried")
        await audd.close()
    }

    func testClosedClientRefusesRequestsInsteadOfTrapping() async throws {
        // An SDK-owned session: after close() Foundation would trap on a new task.
        let session = ManagedSession(urlSession: nil, timeouts: .standard)
        session.close(cancelRunning: true)
        let request = URLRequest(url: URL(string: "https://api.audd.io/")!)
        do {
            _ = try await performDataTask(session: session, request: request)
            XCTFail("expected an error")
        } catch is ClientClosedError {
            // expected
        }

        let audd = try AudD(apiToken: "test")
        await audd.close()
        do {
            _ = try await audd.recognize("https://audd.tech/example.mp3")
            XCTFail("expected an error")
        } catch AudDError.connection(_, let underlying) {
            XCTAssertTrue(underlying is ClientClosedError)
        }
    }
}

func fixtureData(_ name: String) throws -> Data {
    // The contract workflow sets AUDD_OPENAPI_FIXTURES to a checkout of the
    // shared audd-openapi fixtures. Without it, or for a fixture that only
    // exists here, the copies bundled with the tests are used.
    if let dir = ProcessInfo.processInfo.environment["AUDD_OPENAPI_FIXTURES"], !dir.isEmpty {
        let shared = URL(fileURLWithPath: dir).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: shared.path) {
            return try Data(contentsOf: shared)
        }
    }
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        ?? Bundle.module.url(forResource: name, withExtension: nil)
    guard let url else {
        throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture not found: \(name)"])
    }
    return try Data(contentsOf: url)
}
