// Coverage for `RecognitionResult.streamingUrl(_:)` / `streamingUrls()` /
// `previewUrl()`, plus the `EnterpriseMatch` lis.tn-only equivalents.
//
// These helpers cover the documented resolution rules: direct URL from a
// metadata block first, lis.tn redirect second, nil third.
import XCTest
@testable import AudD

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StreamingHelpersTests: XCTestCase {
    func testStreamingUrlLisTnRedirectAllProviders() throws {
        let json: [String: Any] = [
            "timecode": "00:30",
            "artist": "x",
            "title": "y",
            "song_link": "https://lis.tn/AbCdE",
        ]
        let result = try decode(RecognitionResult.self, from: json)
        XCTAssertEqual(result.streamingUrl(.spotify), "https://lis.tn/AbCdE?spotify")
        XCTAssertEqual(result.streamingUrl(.appleMusic), "https://lis.tn/AbCdE?apple_music")
        XCTAssertEqual(result.streamingUrl(.deezer), "https://lis.tn/AbCdE?deezer")
        XCTAssertEqual(result.streamingUrl(.napster), "https://lis.tn/AbCdE?napster")
        XCTAssertEqual(result.streamingUrl(.youtube), "https://lis.tn/AbCdE?youtube")
    }

    func testStreamingUrlNonLisTnHostReturnsNilForYouTube() throws {
        let json: [String: Any] = [
            "timecode": "00:30",
            "artist": "x",
            "song_link": "https://www.youtube.com/watch?v=Ab12",
        ]
        let result = try decode(RecognitionResult.self, from: json)
        // YouTube has only the lis.tn-redirect path: non-lis.tn → nil.
        XCTAssertNil(result.streamingUrl(.youtube))
        // Other providers also nil because no metadata block.
        XCTAssertNil(result.streamingUrl(.spotify))
    }

    func testStreamingUrlPrefersDirectAppleMusicURL() throws {
        // Even with a lis.tn songLink, the direct apple_music.url wins.
        let json: [String: Any] = [
            "timecode": "00:30",
            "artist": "x",
            "song_link": "https://lis.tn/abc",
            "apple_music": [
                "url": "https://music.apple.com/us/album/foo/123",
            ],
        ]
        let result = try decode(RecognitionResult.self, from: json)
        XCTAssertEqual(result.streamingUrl(.appleMusic), "https://music.apple.com/us/album/foo/123")
    }

    func testStreamingUrlSpotifyExternalUrlsFromExtras() throws {
        // Spotify's `external_urls.spotify` lives in extras (not a typed field).
        let json: [String: Any] = [
            "timecode": "00:30",
            "artist": "x",
            "song_link": "https://lis.tn/abc",
            "spotify": [
                "id": "track123",
                "external_urls": ["spotify": "https://open.spotify.com/track/track123"],
            ],
        ]
        let result = try decode(RecognitionResult.self, from: json)
        XCTAssertEqual(result.streamingUrl(.spotify), "https://open.spotify.com/track/track123")
    }

    func testStreamingUrlDeezerLink() throws {
        let json: [String: Any] = [
            "timecode": "00:30",
            "artist": "x",
            "song_link": "https://lis.tn/abc",
            "deezer": [
                "id": 1,
                "link": "https://www.deezer.com/track/1",
            ],
        ]
        let result = try decode(RecognitionResult.self, from: json)
        XCTAssertEqual(result.streamingUrl(.deezer), "https://www.deezer.com/track/1")
    }

    func testStreamingUrlNapsterHrefFromExtras() throws {
        // napster.href is not a typed field — lives in extras.
        let json: [String: Any] = [
            "timecode": "00:30",
            "artist": "x",
            "song_link": "https://lis.tn/abc",
            "napster": [
                "id": "n1",
                "href": "https://napster.com/track/n1",
            ],
        ]
        let result = try decode(RecognitionResult.self, from: json)
        XCTAssertEqual(result.streamingUrl(.napster), "https://napster.com/track/n1")
    }

    func testStreamingUrlsReturnsAllResolvable() throws {
        let json: [String: Any] = [
            "timecode": "00:30",
            "artist": "x",
            "song_link": "https://lis.tn/abc",
            "apple_music": ["url": "https://music.apple.com/x"],
        ]
        let result = try decode(RecognitionResult.self, from: json)
        let urls = result.streamingUrls()
        XCTAssertEqual(urls[.appleMusic], "https://music.apple.com/x")
        XCTAssertEqual(urls[.spotify], "https://lis.tn/abc?spotify")
        XCTAssertEqual(urls[.deezer], "https://lis.tn/abc?deezer")
        XCTAssertEqual(urls[.napster], "https://lis.tn/abc?napster")
        XCTAssertEqual(urls[.youtube], "https://lis.tn/abc?youtube")
    }

    func testStreamingUrlsOnNonLisTnNoMetadataIsEmpty() throws {
        let json: [String: Any] = [
            "timecode": "00:30",
            "artist": "x",
            "song_link": "https://example.com/track/1",
        ]
        let result = try decode(RecognitionResult.self, from: json)
        XCTAssertTrue(result.streamingUrls().isEmpty)
    }

    // MARK: - previewUrl()

    func testPreviewUrlPrefersAppleMusic() throws {
        // From recognize_with_metadata fixture: apple_music.previews[0].url wins.
        let body = try fixtureJSON("recognize_with_metadata.json")
        let inner = body["result"] as! [String: Any]
        let result = try decode(RecognitionResult.self, from: inner)
        XCTAssertEqual(
            result.previewUrl(),
            "https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview221/v4/2a/c5/8e/2ac58ef1-094d-97f6-3f62-a9f6e7684ccd/mzaf_15145928605517237933.plus.aac.p.m4a"
        )
    }

    func testPreviewUrlFallsBackToSpotify() throws {
        let json: [String: Any] = [
            "timecode": "00:30",
            "artist": "x",
            "spotify": [
                "id": "x",
                "preview_url": "https://p.scdn.co/mp3-preview/abc",
            ],
        ]
        let result = try decode(RecognitionResult.self, from: json)
        XCTAssertEqual(result.previewUrl(), "https://p.scdn.co/mp3-preview/abc")
    }

    func testPreviewUrlFallsBackToDeezer() throws {
        let json: [String: Any] = [
            "timecode": "00:30",
            "artist": "x",
            "deezer": [
                "id": 1,
                "preview": "https://cdns-preview-d.dzcdn.net/track/1.mp3",
            ],
        ]
        let result = try decode(RecognitionResult.self, from: json)
        XCTAssertEqual(result.previewUrl(), "https://cdns-preview-d.dzcdn.net/track/1.mp3")
    }

    func testPreviewUrlReturnsNilWhenNoMetadata() throws {
        let json: [String: Any] = ["timecode": "00:30", "artist": "x"]
        let result = try decode(RecognitionResult.self, from: json)
        XCTAssertNil(result.previewUrl())
    }

    // MARK: - EnterpriseMatch lis.tn-only equivalents

    func testEnterpriseMatchStreamingUrlLisTnOnly() throws {
        let json: [String: Any] = [
            "score": 95,
            "timecode": "00:30",
            "artist": "x",
            "title": "y",
            "song_link": "https://lis.tn/Xyz",
        ]
        let match = try decode(EnterpriseMatch.self, from: json)
        XCTAssertEqual(match.streamingUrl(.spotify), "https://lis.tn/Xyz?spotify")
        XCTAssertEqual(match.streamingUrls().count, 5)
    }

    func testEnterpriseMatchStreamingUrlNonLisTnReturnsNil() throws {
        let json: [String: Any] = [
            "score": 95,
            "timecode": "00:30",
            "artist": "x",
            "song_link": "https://www.youtube.com/watch?v=ab",
        ]
        let match = try decode(EnterpriseMatch.self, from: json)
        XCTAssertNil(match.streamingUrl(.spotify))
        XCTAssertTrue(match.streamingUrls().isEmpty)
    }

    func testStreamingProviderRawValuesMatchAudDQueryKeys() {
        XCTAssertEqual(StreamingProvider.spotify.rawValue, "spotify")
        XCTAssertEqual(StreamingProvider.appleMusic.rawValue, "apple_music")
        XCTAssertEqual(StreamingProvider.deezer.rawValue, "deezer")
        XCTAssertEqual(StreamingProvider.napster.rawValue, "napster")
        XCTAssertEqual(StreamingProvider.youtube.rawValue, "youtube")
        XCTAssertEqual(StreamingProvider.allCases.count, 5)
    }
}
