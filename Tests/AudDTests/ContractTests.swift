// Contract tests — validate that the SDK's parsers handle the shared
// audd-openapi/fixtures/*.json captures correctly. Each fixture is a real
// (PII-scrubbed) capture from the live API.
import XCTest
@testable import AudD

final class ContractTests: XCTestCase {
    func testRecognizeBasic() throws {
        let body = try fixtureJSON("recognize_basic.json")
        guard let inner = body["result"] as? [String: Any] else {
            XCTFail("missing result"); return
        }
        let result = try decode(RecognitionResult.self, from: inner)
        XCTAssertEqual(result.artist, "Tears For Fears")
        XCTAssertEqual(result.title, "Everybody Wants To Rule The World")
        XCTAssertEqual(result.timecode, "00:56")
        XCTAssertEqual(result.songLink, "https://lis.tn/NbkVb")
        XCTAssertEqual(result.thumbnailURL, "https://lis.tn/NbkVb?thumb")
    }

    func testRecognizeCustomMatch() throws {
        let body = try fixtureJSON("recognize_custom_match.json")
        let inner = body["result"] as! [String: Any]
        let result = try decode(RecognitionResult.self, from: inner)
        XCTAssertEqual(result.audioID, 146)
        XCTAssertEqual(result.timecode, "01:45")
        XCTAssertTrue(result.isCustomMatch)
        XCTAssertFalse(result.isPublicMatch)
    }

    func testRecognizeWithMetadataAppleAndSpotify() throws {
        let body = try fixtureJSON("recognize_with_metadata.json")
        let inner = body["result"] as! [String: Any]
        let result = try decode(RecognitionResult.self, from: inner)
        XCTAssertEqual(result.appleMusic?.artistName, "Tears for Fears")
        XCTAssertEqual(result.appleMusic?.isrc, "GBUM71403885")
        // The fixture exercises trackNumber / discNumber / composerName too
        XCTAssertEqual(result.appleMusic?.trackNumber, 14)
        XCTAssertEqual(result.appleMusic?.discNumber, 4)
        XCTAssertEqual(result.spotify?.id, "5B9qVIyjqeWkeOAp2tJgqL")
        XCTAssertEqual(result.spotify?.durationMs, 261022)
        XCTAssertNotNil(result.musicbrainz)
        // The musicbrainz "score" can be int — confirm we parse it.
        XCTAssertEqual(result.musicbrainz?.first?.score, 100)
        // Forward-compat: Apple "previews"/"artwork" land in extras.
        XCTAssertNotNil(result.appleMusic?.extras["previews"])
        XCTAssertNotNil(result.appleMusic?.extras["artwork"])
    }

    func testEnterpriseChunkParsing() throws {
        let body = try fixtureJSON("enterprise_with_isrc_upc.json")
        let chunks = body["result"] as! [[String: Any]]
        let chunk = try decode(EnterpriseChunkResult.self, from: chunks[0])
        XCTAssertEqual(chunk.songs.count, 1)
        let match = chunk.songs[0]
        XCTAssertEqual(match.score, 81)
        XCTAssertEqual(match.artist, "Tears For Fears")
        XCTAssertEqual(match.isrc, "GBUM71403885")
        XCTAssertEqual(match.upc, "00602547037169")
    }

    func testStreamsCallbackResultParse() throws {
        let body = try fixtureJSON("streams_callback_with_result.json")
        let payload = try StreamCallbackPayload.parse(body)
        XCTAssertTrue(payload.isResult)
        XCTAssertFalse(payload.isNotification)
        XCTAssertEqual(payload.result?.radioID, 7)
        XCTAssertEqual(payload.result?.results.first?.artist, "Alan Walker, A$AP Rocky")
    }

    func testStreamsCallbackNotificationParse() throws {
        let body = try fixtureJSON("streams_callback_with_notification.json")
        let payload = try StreamCallbackPayload.parse(body)
        XCTAssertFalse(payload.isResult)
        XCTAssertTrue(payload.isNotification)
        XCTAssertEqual(payload.notification?.notificationCode, 650)
        XCTAssertEqual(payload.notification?.radioID, 3)
    }

    func testGetStreamsEmpty() throws {
        let body = try fixtureJSON("getStreams_empty.json")
        let result = body["result"] as! [Any]
        XCTAssertTrue(result.isEmpty)
    }

    func testError900Parses() throws {
        let body = try fixtureJSON("error_900_invalid_token.json")
        let err = makeAPIError(from: body, httpStatus: 200, requestID: nil)
        if case let .api(detail) = err {
            XCTAssertEqual(detail.errorCode, 900)
            XCTAssertEqual(detail.kind, .authentication)
        } else {
            XCTFail("expected api error")
        }
    }

    func testError700Parses() throws {
        let body = try fixtureJSON("error_700_no_file.json")
        let err = makeAPIError(from: body, httpStatus: 200, requestID: nil)
        if case let .api(detail) = err {
            XCTAssertEqual(detail.errorCode, 700)
            XCTAssertEqual(detail.kind, .invalidRequest)
        } else {
            XCTFail("expected api error")
        }
    }

    func testError904SubscriptionVsCustomCatalog() throws {
        let body = try fixtureJSON("error_904_enterprise_unauthorized.json")
        let normalErr = makeAPIError(from: body, httpStatus: 200, requestID: nil)
        if case let .api(detail) = normalErr {
            XCTAssertEqual(detail.kind, .subscription)
        } else {
            XCTFail("expected api error")
        }
        let ccErr = makeAPIError(from: body, httpStatus: 200, requestID: nil, customCatalogContext: true)
        if case let .api(detail) = ccErr {
            XCTAssertEqual(detail.kind, .customCatalogAccess)
            XCTAssertTrue(detail.message.contains("Adding songs to your custom catalog"))
        } else {
            XCTFail("expected api error")
        }
    }

    func testError19BlockedKind() throws {
        let body = try fixtureJSON("error_19_no_callback_url.json")
        let err = makeAPIError(from: body, httpStatus: 200, requestID: nil)
        if case let .api(detail) = err {
            XCTAssertEqual(detail.errorCode, 19)
            // 19 maps to .blocked per spec — but also the streams namespace
            // handles 19-from-getCallbackUrl specially.
            XCTAssertEqual(detail.kind, .blocked)
        } else {
            XCTFail("expected api error")
        }
    }

    func testLongpollNoEvents() throws {
        let body = try fixtureJSON("longpoll_no_events.json")
        XCTAssertEqual(body["timeout"] as? String, "no events before timeout")
        XCTAssertNotNil(body["timestamp"])
    }
}

func fixtureJSON(_ name: String) throws -> [String: Any] {
    let data = try fixtureData(name)
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! [String: Any]
}
