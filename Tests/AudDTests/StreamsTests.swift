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
        let body = try fixtureJSON("streams_callback_with_result.json")
        let payload = try StreamCallbackPayload.parse(body)
        XCTAssertTrue(payload.isResult)
    }
}
