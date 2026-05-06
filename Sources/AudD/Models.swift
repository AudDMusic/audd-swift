// Codable models. Every model uses a custom `init(from:)` that captures any
// unknown keys into `extras: [String: AnyCodable]` and the full payload into
// `rawResponse: AnyCodable?` for forward compatibility (spec §5.2).
import Foundation

// MARK: - Streaming providers (spec §4.3)

/// Streaming services supported by the `streamingUrl(_:)` helper. The raw
/// values are the canonical AudD `?<provider>` query-string keys used by the
/// lis.tn redirect endpoint and by the `return=...` recognition parameter.
public enum StreamingProvider: String, CaseIterable, Sendable {
    case spotify
    case appleMusic = "apple_music"
    case deezer
    case napster
    case youtube
}

/// Build a lis.tn-redirect URL of the form `<songLink>?<provider>` (or
/// `<songLink>&<provider>` when `songLink` already has a query). Returns
/// `nil` when `songLink` is missing/empty/un-parseable, or its host is not
/// `lis.tn`.
func lisTnStreamingURL(songLink: String?, provider: String) -> String? {
    guard let songLink, !songLink.isEmpty else { return nil }
    guard let components = URLComponents(string: songLink) else { return nil }
    guard components.host == "lis.tn" else { return nil }
    let separator = (components.query?.isEmpty == false) ? "&" : "?"
    return "\(songLink)\(separator)\(provider)"
}

// MARK: - Helpers for forward-compat decoding

/// Decode known keys via the model's `CodingKeys`, capture everything else in
/// the `extras` dict.
func decodeExtras<K: CodingKey & CaseIterable & RawRepresentable>(
    from decoder: Decoder,
    knownKeys: K.Type
) throws -> [String: AnyCodable] where K.RawValue == String {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    let known: Set<String> = Set(K.allCases.map { $0.rawValue })
    var extras: [String: AnyCodable] = [:]
    for key in container.allKeys {
        if known.contains(key.stringValue) { continue }
        let value = try container.decode(AnyCodable.self, forKey: key)
        extras[key.stringValue] = value
    }
    return extras
}

/// Decode all top-level keys as a single AnyCodable map (the rawResponse).
func decodeRawResponse(from decoder: Decoder) throws -> AnyCodable {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    var dict: [String: AnyCodable] = [:]
    for key in container.allKeys {
        dict[key.stringValue] = try container.decode(AnyCodable.self, forKey: key)
    }
    return AnyCodable(dict)
}

// MARK: - Recognition metadata

public struct AppleMusicMetadata: Sendable, Equatable, Decodable {
    public let artistName: String?
    public let url: String?
    public let durationInMillis: Int?
    public let name: String?
    public let isrc: String?
    public let albumName: String?
    public let trackNumber: Int?
    public let composerName: String?
    public let discNumber: Int?
    public let releaseDate: String?
    public let extras: [String: AnyCodable]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case artistName, url, durationInMillis, name, isrc, albumName
        case trackNumber, composerName, discNumber, releaseDate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.artistName = try c.decodeIfPresent(String.self, forKey: .artistName)
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.durationInMillis = try c.decodeIfPresent(Int.self, forKey: .durationInMillis)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.isrc = try c.decodeIfPresent(String.self, forKey: .isrc)
        self.albumName = try c.decodeIfPresent(String.self, forKey: .albumName)
        self.trackNumber = try c.decodeIfPresent(Int.self, forKey: .trackNumber)
        self.composerName = try c.decodeIfPresent(String.self, forKey: .composerName)
        self.discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber)
        self.releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
    }
}

public struct SpotifyMetadata: Sendable, Equatable, Decodable {
    public let id: String?
    public let name: String?
    public let durationMs: Int?
    public let explicit: Bool?
    public let popularity: Int?
    public let trackNumber: Int?
    public let type: String?
    public let uri: String?
    public let extras: [String: AnyCodable]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name
        case durationMs = "duration_ms"
        case explicit, popularity
        case trackNumber = "track_number"
        case type, uri
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        self.explicit = try c.decodeIfPresent(Bool.self, forKey: .explicit)
        self.popularity = try c.decodeIfPresent(Int.self, forKey: .popularity)
        self.trackNumber = try c.decodeIfPresent(Int.self, forKey: .trackNumber)
        self.type = try c.decodeIfPresent(String.self, forKey: .type)
        self.uri = try c.decodeIfPresent(String.self, forKey: .uri)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
    }
}

public struct DeezerMetadata: Sendable, Equatable, Decodable {
    public let id: Int?
    public let title: String?
    public let duration: Int?
    public let link: String?
    public let extras: [String: AnyCodable]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, title, duration, link
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(Int.self, forKey: .id)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        self.link = try c.decodeIfPresent(String.self, forKey: .link)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
    }
}

public struct NapsterMetadata: Sendable, Equatable, Decodable {
    public let id: String?
    public let name: String?
    public let isrc: String?
    public let artistName: String?
    public let albumName: String?
    public let extras: [String: AnyCodable]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, isrc, artistName, albumName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.isrc = try c.decodeIfPresent(String.self, forKey: .isrc)
        self.artistName = try c.decodeIfPresent(String.self, forKey: .artistName)
        self.albumName = try c.decodeIfPresent(String.self, forKey: .albumName)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
    }
}

public struct MusicBrainzEntry: Sendable, Equatable, Decodable {
    public let id: String
    public let score: Int?
    public let title: String?
    public let length: Int?
    public let extras: [String: AnyCodable]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, score, title, length
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        // server may send int or string for score
        if let intScore = try? c.decode(Int.self, forKey: .score) {
            self.score = intScore
        } else if let strScore = try? c.decode(String.self, forKey: .score), let parsed = Int(strScore) {
            self.score = parsed
        } else {
            self.score = nil
        }
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.length = try c.decodeIfPresent(Int.self, forKey: .length)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
    }
}

// MARK: - RecognitionResult

public struct RecognitionResult: Sendable, Equatable, Decodable {
    public let timecode: String
    public let audioID: Int?
    public let artist: String?
    public let title: String?
    public let album: String?
    public let releaseDate: String?
    public let label: String?
    public let songLink: String?
    public let appleMusic: AppleMusicMetadata?
    public let spotify: SpotifyMetadata?
    public let deezer: DeezerMetadata?
    public let napster: NapsterMetadata?
    public let musicbrainz: [MusicBrainzEntry]?
    public let extras: [String: AnyCodable]
    public let rawResponse: AnyCodable

    enum CodingKeys: String, CodingKey, CaseIterable {
        case timecode
        case audioID = "audio_id"
        case artist, title, album
        case releaseDate = "release_date"
        case label
        case songLink = "song_link"
        case appleMusic = "apple_music"
        case spotify, deezer, napster, musicbrainz
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.timecode = try c.decode(String.self, forKey: .timecode)
        self.audioID = try c.decodeIfPresent(Int.self, forKey: .audioID)
        self.artist = try c.decodeIfPresent(String.self, forKey: .artist)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.album = try c.decodeIfPresent(String.self, forKey: .album)
        self.releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
        self.label = try c.decodeIfPresent(String.self, forKey: .label)
        self.songLink = try c.decodeIfPresent(String.self, forKey: .songLink)
        self.appleMusic = try c.decodeIfPresent(AppleMusicMetadata.self, forKey: .appleMusic)
        self.spotify = try c.decodeIfPresent(SpotifyMetadata.self, forKey: .spotify)
        self.deezer = try c.decodeIfPresent(DeezerMetadata.self, forKey: .deezer)
        self.napster = try c.decodeIfPresent(NapsterMetadata.self, forKey: .napster)
        self.musicbrainz = try c.decodeIfPresent([MusicBrainzEntry].self, forKey: .musicbrainz)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
        self.rawResponse = try decodeRawResponse(from: decoder)
    }

    /// `true` when the match came from the caller's private custom catalog
    /// (i.e. `audio_id` is set).
    public var isCustomMatch: Bool {
        audioID != nil
    }

    /// `true` when the match came from AudD's public catalog (artist/title set).
    public var isPublicMatch: Bool {
        audioID == nil && (artist != nil || title != nil)
    }

    /// Cover-art URL for `lis.tn`-hosted song links. Returns `nil` for YouTube
    /// and other hosts (which have no thumb endpoint).
    public var thumbnailURL: String? {
        return lisTnStreamingURL(songLink: songLink, provider: "thumb")
    }

    /// Direct or redirect URL for a streaming provider, with smart fallback.
    ///
    /// Resolution order (spec §4.3):
    /// 1. **Direct URL from the metadata block** when the user requested that
    ///    provider via `return=...` — `apple_music.url`,
    ///    `spotify.external_urls.spotify` (or `spotify.uri` as a secondary
    ///    fallback), `deezer.link`, `napster.href`. Direct = no redirect,
    ///    faster for clients.
    /// 2. **lis.tn redirect** `"\(songLink)?\(provider.rawValue)"` when
    ///    `songLink`'s host is `lis.tn`.
    /// 3. `nil` otherwise. YouTube has only the lis.tn-redirect path.
    public func streamingUrl(_ provider: StreamingProvider) -> String? {
        if let direct = directStreamingURL(for: provider) {
            return direct
        }
        return lisTnStreamingURL(songLink: songLink, provider: provider.rawValue)
    }

    private func directStreamingURL(for provider: StreamingProvider) -> String? {
        switch provider {
        case .appleMusic:
            if let url = appleMusic?.url, !url.isEmpty { return url }
        case .spotify:
            if let spotify = spotify {
                if let externalURLs = spotify.extras["external_urls"]?.value as? [String: Any],
                   let url = externalURLs["spotify"] as? String, !url.isEmpty {
                    return url
                }
                if let externalURLs = spotify.extras["external_urls"]?.value as? [String: AnyCodable],
                   let url = externalURLs["spotify"]?.value as? String, !url.isEmpty {
                    return url
                }
                if let uri = spotify.uri, !uri.isEmpty { return uri }
            }
        case .deezer:
            if let link = deezer?.link, !link.isEmpty { return link }
        case .napster:
            if let napster = napster,
               let href = napster.extras["href"]?.value as? String, !href.isEmpty {
                return href
            }
        case .youtube:
            // YouTube has no metadata block; lis.tn redirect is the only path.
            return nil
        }
        return nil
    }

    /// Map of every provider with a resolvable URL — direct or via lis.tn redirect.
    public func streamingUrls() -> [StreamingProvider: String] {
        var out: [StreamingProvider: String] = [:]
        for p in StreamingProvider.allCases {
            if let url = streamingUrl(p) {
                out[p] = url
            }
        }
        return out
    }

    /// First available 30-second preview URL across providers, in priority
    /// order: `apple_music.previews[0].url` → `spotify.preview_url` →
    /// `deezer.preview`.
    ///
    /// **Note:** previews are governed by the respective providers' terms of
    /// use (Apple Music, Spotify, Deezer). The SDK consumer is responsible
    /// for honoring those terms — including caching restrictions, attribution
    /// requirements, and any redistribution constraints.
    public func previewUrl() -> String? {
        // Apple Music: previews lives in extras (not a typed field).
        if let appleMusic = appleMusic {
            if let previewsAny = appleMusic.extras["previews"]?.value {
                if let previewsArr = previewsAny as? [[String: Any]],
                   let first = previewsArr.first,
                   let url = first["url"] as? String, !url.isEmpty {
                    return url
                }
                if let previewsArr = previewsAny as? [AnyCodable],
                   let firstAny = previewsArr.first?.value {
                    if let firstDict = firstAny as? [String: Any],
                       let url = firstDict["url"] as? String, !url.isEmpty {
                        return url
                    }
                    if let firstDict = firstAny as? [String: AnyCodable],
                       let url = firstDict["url"]?.value as? String, !url.isEmpty {
                        return url
                    }
                }
            }
        }
        // Spotify: preview_url is a top-level field, lives in extras.
        if let spotify = spotify,
           let url = spotify.extras["preview_url"]?.value as? String, !url.isEmpty {
            return url
        }
        // Deezer: preview is a top-level field, lives in extras.
        if let deezer = deezer,
           let url = deezer.extras["preview"]?.value as? String, !url.isEmpty {
            return url
        }
        return nil
    }
}

// MARK: - Enterprise

public struct EnterpriseMatch: Sendable, Equatable, Decodable {
    public let score: Int
    public let timecode: String
    public let artist: String?
    public let title: String?
    public let album: String?
    public let releaseDate: String?
    public let label: String?
    public let isrc: String?
    public let upc: String?
    public let songLink: String?
    public let startOffset: Int?
    public let endOffset: Int?
    public let extras: [String: AnyCodable]
    public let rawResponse: AnyCodable

    enum CodingKeys: String, CodingKey, CaseIterable {
        case score, timecode, artist, title, album
        case releaseDate = "release_date"
        case label, isrc, upc
        case songLink = "song_link"
        case startOffset = "start_offset"
        case endOffset = "end_offset"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.score = try c.decode(Int.self, forKey: .score)
        self.timecode = try c.decode(String.self, forKey: .timecode)
        self.artist = try c.decodeIfPresent(String.self, forKey: .artist)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.album = try c.decodeIfPresent(String.self, forKey: .album)
        self.releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
        self.label = try c.decodeIfPresent(String.self, forKey: .label)
        self.isrc = try c.decodeIfPresent(String.self, forKey: .isrc)
        self.upc = try c.decodeIfPresent(String.self, forKey: .upc)
        self.songLink = try c.decodeIfPresent(String.self, forKey: .songLink)
        self.startOffset = try c.decodeIfPresent(Int.self, forKey: .startOffset)
        self.endOffset = try c.decodeIfPresent(Int.self, forKey: .endOffset)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
        self.rawResponse = try decodeRawResponse(from: decoder)
    }

    public var isCustomMatch: Bool { false }
    public var isPublicMatch: Bool { artist != nil || title != nil }
    public var thumbnailURL: String? {
        return lisTnStreamingURL(songLink: songLink, provider: "thumb")
    }

    /// lis.tn-redirect URL for the given streaming provider. Returns `nil`
    /// when `songLink` is missing or hosted off lis.tn — enterprise responses
    /// don't carry per-provider metadata blocks, so there's no direct-URL
    /// fallback here. See `RecognitionResult.streamingUrl(_:)` for the full
    /// resolution rules.
    public func streamingUrl(_ provider: StreamingProvider) -> String? {
        return lisTnStreamingURL(songLink: songLink, provider: provider.rawValue)
    }

    /// All providers with a resolvable lis.tn-redirect URL — empty when
    /// `songLink` is missing or hosted off lis.tn.
    public func streamingUrls() -> [StreamingProvider: String] {
        var out: [StreamingProvider: String] = [:]
        for p in StreamingProvider.allCases {
            if let url = streamingUrl(p) {
                out[p] = url
            }
        }
        return out
    }
}

struct EnterpriseChunkResult: Decodable {
    let songs: [EnterpriseMatch]
    let offset: String

    enum CodingKeys: String, CodingKey {
        case songs, offset
    }
}

// MARK: - Streams

public struct Stream: Sendable, Equatable, Decodable {
    public let radioID: Int
    public let url: String
    public let streamRunning: Bool
    public let longpollCategory: String?
    public let extras: [String: AnyCodable]
    public let rawResponse: AnyCodable

    enum CodingKeys: String, CodingKey, CaseIterable {
        case radioID = "radio_id"
        case url
        case streamRunning = "stream_running"
        case longpollCategory = "longpoll_category"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.radioID = try c.decode(Int.self, forKey: .radioID)
        self.url = try c.decode(String.self, forKey: .url)
        self.streamRunning = try c.decode(Bool.self, forKey: .streamRunning)
        self.longpollCategory = try c.decodeIfPresent(String.self, forKey: .longpollCategory)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
        self.rawResponse = try decodeRawResponse(from: decoder)
    }
}

public struct StreamCallbackResultEntry: Sendable, Equatable, Decodable {
    public let artist: String
    public let title: String
    public let score: Int
    public let album: String?
    public let releaseDate: String?
    public let label: String?
    public let songLink: String?
    public let appleMusic: AppleMusicMetadata?
    public let spotify: SpotifyMetadata?
    public let deezer: DeezerMetadata?
    public let napster: NapsterMetadata?
    public let musicbrainz: [MusicBrainzEntry]?
    public let extras: [String: AnyCodable]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case artist, title, score, album
        case releaseDate = "release_date"
        case label
        case songLink = "song_link"
        case appleMusic = "apple_music"
        case spotify, deezer, napster, musicbrainz
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.artist = try c.decode(String.self, forKey: .artist)
        self.title = try c.decode(String.self, forKey: .title)
        self.score = try c.decode(Int.self, forKey: .score)
        self.album = try c.decodeIfPresent(String.self, forKey: .album)
        self.releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
        self.label = try c.decodeIfPresent(String.self, forKey: .label)
        self.songLink = try c.decodeIfPresent(String.self, forKey: .songLink)
        self.appleMusic = try c.decodeIfPresent(AppleMusicMetadata.self, forKey: .appleMusic)
        self.spotify = try c.decodeIfPresent(SpotifyMetadata.self, forKey: .spotify)
        self.deezer = try c.decodeIfPresent(DeezerMetadata.self, forKey: .deezer)
        self.napster = try c.decodeIfPresent(NapsterMetadata.self, forKey: .napster)
        self.musicbrainz = try c.decodeIfPresent([MusicBrainzEntry].self, forKey: .musicbrainz)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
    }
}

public struct StreamCallbackResult: Sendable, Equatable, Decodable {
    public let radioID: Int
    public let timestamp: String?
    public let playLength: Int?
    public let results: [StreamCallbackResultEntry]
    public let extras: [String: AnyCodable]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case radioID = "radio_id"
        case timestamp
        case playLength = "play_length"
        case results
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.radioID = try c.decode(Int.self, forKey: .radioID)
        self.timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
        self.playLength = try c.decodeIfPresent(Int.self, forKey: .playLength)
        self.results = try c.decode([StreamCallbackResultEntry].self, forKey: .results)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
    }
}

public struct StreamCallbackNotification: Sendable, Equatable, Decodable {
    public let radioID: Int
    public let streamRunning: Bool?
    public let notificationCode: Int
    public let notificationMessage: String
    public let extras: [String: AnyCodable]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case radioID = "radio_id"
        case streamRunning = "stream_running"
        case notificationCode = "notification_code"
        case notificationMessage = "notification_message"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.radioID = try c.decode(Int.self, forKey: .radioID)
        self.streamRunning = try c.decodeIfPresent(Bool.self, forKey: .streamRunning)
        self.notificationCode = try c.decode(Int.self, forKey: .notificationCode)
        self.notificationMessage = try c.decode(String.self, forKey: .notificationMessage)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
    }
}

/// A callback payload — either a recognition result or a notification.
public struct StreamCallbackPayload: Sendable, Equatable {
    public let result: StreamCallbackResult?
    public let notification: StreamCallbackNotification?
    public let time: Int?
    public let rawPayload: AnyCodable

    public var isResult: Bool { result != nil }
    public var isNotification: Bool { notification != nil }

    public static func parse(_ body: [String: Any]) throws -> StreamCallbackPayload {
        let raw = AnyCodable(body)
        // Notification variant
        if let notifDict = body["notification"] as? [String: Any] {
            let notif = try decodeFromAny(StreamCallbackNotification.self, dict: notifDict)
            let time = body["time"] as? Int
            return StreamCallbackPayload(result: nil, notification: notif, time: time, rawPayload: raw)
        }
        // Result variant
        let inner = (body["result"] as? [String: Any]) ?? [:]
        let result = try decodeFromAny(StreamCallbackResult.self, dict: inner)
        return StreamCallbackPayload(result: result, notification: nil, time: nil, rawPayload: raw)
    }
}

private func decodeFromAny<T: Decodable>(_ type: T.Type, dict: [String: Any]) throws -> T {
    let data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: dict, options: [])
    } catch {
        throw AudDError.serializationError(message: "Could not re-encode for decoding: \(error.localizedDescription)", rawText: "")
    }
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        throw AudDError.serializationError(message: "Could not decode \(T.self): \(error.localizedDescription)", rawText: String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - Lyrics

public struct LyricsResult: Sendable, Equatable, Decodable {
    public let artist: String
    public let title: String
    public let lyrics: String?
    public let songID: Int?
    public let media: String?
    public let fullTitle: String?
    public let artistID: Int?
    public let songLink: String?
    public let extras: [String: AnyCodable]
    public let rawResponse: AnyCodable

    enum CodingKeys: String, CodingKey, CaseIterable {
        case artist, title, lyrics
        case songID = "song_id"
        case media
        case fullTitle = "full_title"
        case artistID = "artist_id"
        case songLink = "song_link"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.artist = try c.decode(String.self, forKey: .artist)
        self.title = try c.decode(String.self, forKey: .title)
        self.lyrics = try c.decodeIfPresent(String.self, forKey: .lyrics)
        self.songID = try c.decodeIfPresent(Int.self, forKey: .songID)
        self.media = try c.decodeIfPresent(String.self, forKey: .media)
        self.fullTitle = try c.decodeIfPresent(String.self, forKey: .fullTitle)
        self.artistID = try c.decodeIfPresent(Int.self, forKey: .artistID)
        self.songLink = try c.decodeIfPresent(String.self, forKey: .songLink)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
        self.rawResponse = try decodeRawResponse(from: decoder)
    }
}
