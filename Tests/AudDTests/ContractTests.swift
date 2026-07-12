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

    /// An enterprise response whose song omits `score` (and `isrc`/`upc`/`label`)
    /// must decode without throwing — those fields are not structurally
    /// guaranteed on the enterprise endpoint. Regression for the
    /// `keyNotFound`/`typeMismatch`-on-success bug.
    func testEnterpriseSongMissingScoreDoesNotThrow() throws {
        let body: [String: Any] = [
            "status": "success",
            "result": [
                [
                    "songs": [
                        [
                            "artist": "Some Artist",
                            "title": "Some Title",
                            "timecode": "00:00",
                            "song_link": "https://lis.tn/abc",
                        ],
                    ],
                    "offset": "0",
                ],
            ],
        ]
        let chunks = body["result"] as! [[String: Any]]
        let chunk = try decode(EnterpriseChunkResult.self, from: chunks[0])
        XCTAssertEqual(chunk.songs.count, 1)
        let match = chunk.songs[0]
        XCTAssertNil(match.score)
        XCTAssertNil(match.isrc)
        XCTAssertNil(match.upc)
        XCTAssertNil(match.label)
        XCTAssertEqual(match.artist, "Some Artist")
        XCTAssertEqual(match.title, "Some Title")
    }

    func testStreamsCallbackResultParse() throws {
        let data = try fixtureData("streams_callback_with_result.json")
        let parsed = try Audd_parseCallback(data)
        guard case .match(let match) = parsed else {
            XCTFail("expected .match, got \(parsed)"); return
        }
        XCTAssertEqual(match.radioID, 7)
        XCTAssertEqual(match.song?.artist, "Alan Walker, A$AP Rocky")
        XCTAssertEqual(match.song?.title, "Live Fast (PUBGM)")
        XCTAssertEqual(match.alternatives.count, 0)
    }

    func testStreamsCallbackNotificationParse() throws {
        let data = try fixtureData("streams_callback_with_notification.json")
        let parsed = try Audd_parseCallback(data)
        guard case .notification(let notif) = parsed else {
            XCTFail("expected .notification, got \(parsed)"); return
        }
        XCTAssertEqual(notif.notificationCode, 650)
        XCTAssertEqual(notif.radioID, 3)
        XCTAssertEqual(notif.time, 1587939136)
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

    // MARK: - Wrong-typed scalar fields must degrade to nil, never throw

    /// A recognition response with wrong-typed scalars must decode without
    /// throwing. Convertible values are coerced (`123` → `"123"`); a
    /// non-numeric string for an `Int` field degrades to `nil`. Well-typed
    /// neighbors still decode.
    func testRecognizeWrongTypedScalarsCoerceOrDegrade() throws {
        let inner: [String: Any] = [
            "artist": 123,          // number where String expected → "123"
            "title": "Real Title",  // correct type — must survive
            "audio_id": "not-a-number", // non-numeric string where Int expected → nil
            "song_link": "https://lis.tn/abc",
        ]
        let result = try decode(RecognitionResult.self, from: inner)
        XCTAssertEqual(result.artist, "123")
        XCTAssertNil(result.audioID)
        XCTAssertEqual(result.title, "Real Title")
        XCTAssertEqual(result.songLink, "https://lis.tn/abc")
        // The malformed values are still preserved in the raw payload.
        XCTAssertNotNil(result.rawResponse.value)
    }

    /// A provider metadata block whose scalar arrives with the wrong type must
    /// still decode: a convertible number coerces to `String` (`12345` →
    /// `"12345"`), an unconvertible string for an `Int` field degrades to `nil`,
    /// and siblings survive.
    func testProviderWrongTypedScalarCoerceOrDegrade() throws {
        let inner: [String: Any] = [
            "artist": "Some Artist",
            "title": "Some Title",
            "spotify": [
                "id": 12345,        // number where String expected → "12345"
                "name": "Track Name",
                "duration_ms": "abc", // non-numeric string where Int expected → nil
            ],
        ]
        let result = try decode(RecognitionResult.self, from: inner)
        XCTAssertNotNil(result.spotify)
        XCTAssertEqual(result.spotify?.id, "12345")
        XCTAssertNil(result.spotify?.durationMs)
        XCTAssertEqual(result.spotify?.name, "Track Name")
    }

    /// An enterprise match whose `score` arrives as a string (rather than the
    /// expected number) must degrade to `nil` without throwing.
    func testEnterpriseWrongTypedScoreDoesNotThrow() throws {
        let body: [String: Any] = [
            "result": [
                [
                    "songs": [
                        [
                            "artist": "Some Artist",
                            "title": "Some Title",
                            "score": "eighty-one", // string where Int expected
                        ],
                    ],
                    "offset": "0",
                ],
            ],
        ]
        let chunks = body["result"] as! [[String: Any]]
        let chunk = try decode(EnterpriseChunkResult.self, from: chunks[0])
        XCTAssertEqual(chunk.songs.count, 1)
        XCTAssertNil(chunk.songs[0].score)
        XCTAssertEqual(chunk.songs[0].artist, "Some Artist")
    }

    /// A stream-callback song whose `score` arrives with the wrong type must
    /// still parse — the field degrades to `nil` and the match survives.
    func testStreamCallbackWrongTypedScoreDoesNotThrow() throws {
        let inner: [String: Any] = [
            "radio_id": 7,
            "results": [
                [
                    "artist": "Some Artist",
                    "title": "Some Title",
                    "score": ["unexpected": "object"], // object where Int expected
                ],
            ],
        ]
        let match = try decode(StreamCallbackMatch.self, from: inner)
        XCTAssertNotNil(match.song)
        XCTAssertNil(match.song?.score)
        XCTAssertEqual(match.song?.artist, "Some Artist")
        XCTAssertEqual(match.song?.title, "Some Title")
    }

    // MARK: - Scalar coercion (family coercion policy)

    /// An enterprise match `score` (an `Int` field) that arrives as a numeric
    /// string is parsed exactly; a fractional/wrong-typed neighbor coerces per
    /// policy.
    func testEnterpriseNumericStringScoreCoerces() throws {
        let inner: [String: Any] = [
            "songs": [
                [
                    "artist": "Some Artist",
                    "title": "Some Title",
                    "score": "85", // numeric string where Int expected → 85
                ],
            ],
            "offset": "0",
        ]
        let chunk = try decode(EnterpriseChunkResult.self, from: inner)
        XCTAssertEqual(chunk.songs[0].score, 85)
    }

    /// Direct, exhaustive coverage of the `decodeLenient` scalar-coercion
    /// overloads, keyed by target type.
    func testScalarCoercionMatrix() throws {
        // expect Int -----------------------------------------------------
        XCTAssertEqual(coerceInt(["v": "85"]), 85)          // numeric string
        XCTAssertEqual(coerceInt(["v": " 85 "]), 85)        // trimmed
        XCTAssertEqual(coerceInt(["v": 85.7]), 85)          // double truncates
        XCTAssertEqual(coerceInt(["v": true]), 1)           // bool → 1
        XCTAssertEqual(coerceInt(["v": false]), 0)          // bool → 0
        XCTAssertNil(coerceInt(["v": "abc"]))               // non-numeric string
        XCTAssertNil(coerceInt(["v": "85abc"]))             // partial numeric
        XCTAssertNil(coerceInt(["v": ["x": 1]]))            // object
        XCTAssertNil(coerceInt(["v": [1, 2]]))              // array
        XCTAssertNil(coerceInt([:]))                        // missing

        // expect String --------------------------------------------------
        XCTAssertEqual(coerceString(["v": 123]), "123")     // int → "123" (no ".0")
        XCTAssertEqual(coerceString(["v": 8.5]), "8.5")     // double → "8.5"
        XCTAssertEqual(coerceString(["v": true]), "true")   // bool → "true"
        XCTAssertEqual(coerceString(["v": false]), "false")
        XCTAssertNil(coerceString(["v": ["x": 1]]))         // object → nil
        XCTAssertNil(coerceString(["v": [1, 2]]))           // array → nil

        // expect Double --------------------------------------------------
        XCTAssertEqual(coerceDouble(["v": 42]), 42.0)       // int → double
        XCTAssertEqual(coerceDouble(["v": "8.5"]), 8.5)     // numeric string
        XCTAssertEqual(coerceDouble(["v": " 8.5 "]), 8.5)   // trimmed
        XCTAssertNil(coerceDouble(["v": "abc"]))            // non-numeric
        XCTAssertNil(coerceDouble(["v": "NaN"]))            // non-finite rejected
        XCTAssertNil(coerceDouble(["v": "Infinity"]))       // non-finite rejected
        XCTAssertNil(coerceDouble(["v": "inf"]))            // non-finite rejected
        XCTAssertNil(coerceDouble(["v": ["x": 1]]))         // object → nil

        // expect Bool ----------------------------------------------------
        // number → (value != 0)
        XCTAssertEqual(coerceBool(["v": 1]), true)
        XCTAssertEqual(coerceBool(["v": 0]), false)
        XCTAssertEqual(coerceBool(["v": 2]), true)
        // string whitelist — true side
        XCTAssertEqual(coerceBool(["v": "true"]), true)
        XCTAssertEqual(coerceBool(["v": "TRUE"]), true)
        XCTAssertEqual(coerceBool(["v": " 1 "]), true)
        XCTAssertEqual(coerceBool(["v": "yes"]), true)
        XCTAssertEqual(coerceBool(["v": "on"]), true)
        // string whitelist — false side
        XCTAssertEqual(coerceBool(["v": "false"]), false)
        XCTAssertEqual(coerceBool(["v": "False"]), false)
        XCTAssertEqual(coerceBool(["v": "0"]), false)
        XCTAssertEqual(coerceBool(["v": "no"]), false)
        XCTAssertEqual(coerceBool(["v": "off"]), false)
        XCTAssertEqual(coerceBool(["v": ""]), false)
        // unrecognized strings → nil (NOT true)
        XCTAssertNil(coerceBool(["v": "maybe"]))
        XCTAssertNil(coerceBool(["v": "weird"]))
        // containers → nil
        XCTAssertNil(coerceBool(["v": ["x": 1]]))
        XCTAssertNil(coerceBool(["v": [1, 2]]))
    }
}

// MARK: - Coercion test harness

/// A single-key coding container used to exercise `decodeLenient` directly for
/// each scalar target type. The value at key `"v"` is decoded through the
/// lenient helper; a missing key yields `nil`.
private enum CoercionKey: String, CodingKey { case v }

// Each probe binds the concrete scalar overload of `decodeLenient` at its call
// site (a generic wrapper would resolve to the non-coercing generic overload).
private struct IntProbe: Decodable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CoercionKey.self)
        self.value = decodeLenient(Int.self, forKey: .v, in: c)
    }
}
private struct StringProbe: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CoercionKey.self)
        self.value = decodeLenient(String.self, forKey: .v, in: c)
    }
}
private struct DoubleProbe: Decodable {
    let value: Double?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CoercionKey.self)
        self.value = decodeLenient(Double.self, forKey: .v, in: c)
    }
}
private struct BoolProbe: Decodable {
    let value: Bool?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CoercionKey.self)
        self.value = decodeLenient(Bool.self, forKey: .v, in: c)
    }
}

private func decodeProbe<P: Decodable>(_ type: P.Type, _ json: [String: Any]) -> P? {
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try? JSONDecoder().decode(P.self, from: data)
}

private func coerceInt(_ json: [String: Any]) -> Int? { decodeProbe(IntProbe.self, json)?.value }
private func coerceString(_ json: [String: Any]) -> String? { decodeProbe(StringProbe.self, json)?.value }
private func coerceDouble(_ json: [String: Any]) -> Double? { decodeProbe(DoubleProbe.self, json)?.value }
private func coerceBool(_ json: [String: Any]) -> Bool? { decodeProbe(BoolProbe.self, json)?.value }

func fixtureJSON(_ name: String) throws -> [String: Any] {
    let data = try fixtureData(name)
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! [String: Any]
}
