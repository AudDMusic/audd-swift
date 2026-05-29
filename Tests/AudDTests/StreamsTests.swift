// Streams namespace + LongpollConsumer + helper coverage.
import XCTest
@testable import AudD

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StreamsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testListStreamsEmpty() async throws {
        let session = mockSession()
        let payload = try fixtureData("getStreams_empty.json")
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        let streams = try await audd.streams.list()
        XCTAssertEqual(streams.count, 0)
        await audd.close()
    }

    func testListStreamsWithEntry() async throws {
        let session = mockSession()
        let body: [String: Any] = [
            "status": "success",
            "result": [
                ["radio_id": 7, "url": "https://example.com/stream", "stream_running": true, "longpoll_category": "abc123def"],
            ],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        let streams = try await audd.streams.list()
        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(streams[0].radioID, 7)
        XCTAssertEqual(streams[0].streamRunning, true)
        XCTAssertEqual(streams[0].longpollCategory, "abc123def")
        await audd.close()
    }

    func testGetCallbackURLSurfacesCode19AsBlocked() async throws {
        // Direct getCallbackUrl call should surface as .blocked (code 19) per the
        // generic error mapping. The longpoll preflight wraps this differently.
        let session = mockSession()
        let payload = try fixtureData("error_19_no_callback_url.json")
        MockURLProtocol.register { request in
            (makeJSONResponse(request.url!, body: payload), payload)
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        do {
            _ = try await audd.streams.getCallbackURL()
            XCTFail("expected error")
        } catch let AudDError.api(detail) {
            XCTAssertEqual(detail.errorCode, 19)
            XCTAssertEqual(detail.kind, .blocked)
        } catch {
            XCTFail("unexpected: \(error)")
        }
        await audd.close()
    }

    func testDeriveLongpollCategoryFormula() {
        // Formula: md5(md5(token) + str(radio_id))[..9].
        // Verify by computing manually.
        let token = "test"
        let radioID = 1
        // md5("test") = 098f6bcd4621d373cade4e832627b4f6
        // md5("098f6bcd4621d373cade4e832627b4f61") = ...
        // We don't hardcode the expected output; just that it's 9 chars hex and
        // re-runs deterministic.
        let cat1 = Audd_deriveLongpollCategory(apiToken: token, radioID: radioID)
        let cat2 = Audd_deriveLongpollCategory(apiToken: token, radioID: radioID)
        XCTAssertEqual(cat1.count, 9)
        XCTAssertEqual(cat1, cat2)
        // Different radioID → different category
        let cat3 = Audd_deriveLongpollCategory(apiToken: token, radioID: 2)
        XCTAssertNotEqual(cat1, cat3)
        // All hex chars
        XCTAssertTrue(cat1.allSatisfy { $0.isHexDigit })
    }

    func testMD5KnownVectors() {
        // Standard MD5 test vectors from RFC 1321.
        XCTAssertEqual(Audd_md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(Audd_md5Hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(Audd_md5Hex("The quick brown fox jumps over the lazy dog"),
                       "9e107d9d372bb6826bd81d3542a419d6")
    }

    func testAddReturnToURLAppendsCSVMetadata() throws {
        let url = "https://example.com/cb"
        let merged = try addReturnToURL(url, returnMetadata: ["apple_music", "spotify"])
        XCTAssertTrue(merged.contains("return=apple_music%2Cspotify") || merged.contains("return=apple_music,spotify"))
    }

    func testAddReturnToURLConflictRaises() {
        let url = "https://example.com/cb?return=spotify"
        do {
            _ = try addReturnToURL(url, returnMetadata: ["apple_music"])
            XCTFail("expected error")
        } catch let AudDError.api(detail) {
            XCTAssertTrue(detail.message.contains("return"))
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testAddReturnToURLNoMetadataIsPassThrough() throws {
        let url = "https://example.com/cb"
        XCTAssertEqual(try addReturnToURL(url, returnMetadata: nil), url)
        XCTAssertEqual(try addReturnToURL(url, returnMetadata: []), url)
    }

    func testParseCallback() throws {
        let data = try fixtureData("streams_callback_with_result.json")
        let parsed = try Audd_parseCallback(data)
        guard case .match(let match) = parsed else {
            XCTFail("expected .match"); return
        }
        XCTAssertEqual(match.song?.artist, "Alan Walker, A$AP Rocky")
    }

    func testParseCallbackAlternativesSplit() throws {
        // Synthetic envelope with two results — top is `song`, second is in
        // `alternatives` and may carry a different artist/title (variant
        // catalog releases).
        let body: [String: Any] = [
            "result": [
                "radio_id": 7,
                "timestamp": "2020-04-13 10:31:43",
                "results": [
                    ["artist": "A", "title": "T1", "score": 100],
                    ["artist": "B", "title": "T2", "score": 95],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let parsed = try Audd_parseCallback(data)
        guard case .match(let match) = parsed else {
            XCTFail("expected .match"); return
        }
        XCTAssertEqual(match.song?.artist, "A")
        XCTAssertEqual(match.alternatives.count, 1)
        XCTAssertEqual(match.alternatives[0].artist, "B")
        XCTAssertEqual(match.alternatives[0].title, "T2")
    }

    func testParseCallbackEmptyResultsYieldsMatchWithNilSong() throws {
        // An empty `results` array must NOT throw: a successful callback parses
        // into a match with `song == nil` and no alternatives.
        let body: [String: Any] = ["result": ["radio_id": 1, "results": []]]
        let data = try JSONSerialization.data(withJSONObject: body)
        let parsed = try Audd_parseCallback(data)
        guard case .match(let match) = parsed else {
            XCTFail("expected .match, got \(parsed)"); return
        }
        XCTAssertNil(match.song)
        XCTAssertTrue(match.alternatives.isEmpty)
        XCTAssertEqual(match.radioID, 1)
    }

    func testParseCallbackNeitherKeyThrows() throws {
        let body: [String: Any] = ["status": "weird"]
        let data = try JSONSerialization.data(withJSONObject: body)
        XCTAssertThrowsError(try Audd_parseCallback(data))
    }

    // MARK: - longpoll(radioID:) overload

    func testLongpollByRadioIDDerivesSameCategory() async throws {
        // Calling longpoll(radioID:) must hit the longpoll endpoint with the
        // category that `deriveLongpollCategory(radioID:)` produces locally.
        let session = mockSession()
        let payload = try fixtureData("longpoll_no_events.json")
        nonisolated(unsafe) var capturedCategory: String?
        MockURLProtocol.register { request in
            // Route based on URL path: skip callback preflight (won't run with
            // skipCallbackCheck), capture category from the longpoll GET.
            if request.url?.path.contains("longpoll") == true {
                let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                capturedCategory = comps?.queryItems?.first(where: { $0.name == "category" })?.value
                return (makeJSONResponse(request.url!, body: payload), payload)
            }
            throw MockHandlerSkip.skip
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        let expected = await audd.streams.deriveLongpollCategory(radioID: 1)

        let poll = try await audd.streams.longpoll(
            radioID: 1,
            options: LongpollOptions(timeout: 1, skipCallbackCheck: true)
        )
        // Give the loop one tick to fetch.
        try await Task.sleep(nanoseconds: 100_000_000)
        await poll.close()

        XCTAssertEqual(capturedCategory, expected)
        XCTAssertEqual(expected.count, 9)
        await audd.close()
    }

    func testLongpollByCategoryStillWorks() async throws {
        // Tokenless / pre-derived form remains the path for share-without-token.
        let session = mockSession()
        let payload = try fixtureData("longpoll_no_events.json")
        nonisolated(unsafe) var capturedCategory: String?
        MockURLProtocol.register { request in
            if request.url?.path.contains("longpoll") == true {
                let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                capturedCategory = comps?.queryItems?.first(where: { $0.name == "category" })?.value
                return (makeJSONResponse(request.url!, body: payload), payload)
            }
            throw MockHandlerSkip.skip
        }
        let audd = try AudD(apiToken: "test", urlSession: session)
        let poll = try await audd.streams.longpoll(
            category: "abc123def",
            options: LongpollOptions(timeout: 1, skipCallbackCheck: true)
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        await poll.close()

        XCTAssertEqual(capturedCategory, "abc123def")
        await audd.close()
    }
}
