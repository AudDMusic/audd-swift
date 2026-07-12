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

/// Decode a scalar field leniently. A missing key or a `null` yields `nil`. For
/// non-scalar target types a value of the wrong type also yields `nil` — a
/// successful API response must never fail to parse because one field arrived
/// with an unexpected shape.
///
/// The concrete overloads below (`String`, `Int`, `Double`, `Bool`) additionally
/// *coerce* a convertible wrong-typed scalar to the expected type (e.g.
/// `{"score": "85"}` → `85`, `{"artist": 123}` → `"123"`), degrading to `nil`
/// only when the value cannot be converted (e.g. `{"score": "abc"}` → `nil`) or
/// arrived as a non-scalar container (object/array).
func decodeLenient<T: Decodable, K: CodingKey>(
    _ type: T.Type,
    forKey key: K,
    in container: KeyedDecodingContainer<K>
) -> T? {
    return (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
}

// MARK: Scalar coercion overloads (family coercion policy)

/// The concrete JSON scalar that actually arrived for a key, used by the
/// coercion overloads to convert across scalar types. Objects and arrays are
/// deliberately *not* represented here — the coercion helpers treat them as
/// unconvertible and return `nil`.
private enum LenientScalar {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

/// Parse a numeric string to `Double` under the family policy: full-string
/// strict after trimming, and non-finite spellings (`NaN`, `Infinity`, `inf`,
/// …) are rejected even though `Double(_:)` would otherwise accept them.
private func lenientDouble(from string: String) -> Double? {
    let trimmed = string.trimmingCharacters(in: .whitespaces)
    guard let value = Double(trimmed), value.isFinite else { return nil }
    return value
}

/// Read the raw scalar present at `key`. Returns `nil` when the key is missing,
/// `null`, or holds a non-scalar container. `Bool` is probed before the numeric
/// types because Foundation's `JSONDecoder` will happily decode a JSON boolean
/// as a number; probing numbers first would mis-render `true` as `1`.
private func lenientScalar<K: CodingKey>(
    forKey key: K,
    in container: KeyedDecodingContainer<K>
) -> LenientScalar? {
    guard container.contains(key),
          (try? container.decodeNil(forKey: key)) == false else { return nil }
    if let b = try? container.decode(Bool.self, forKey: key) { return .bool(b) }
    if let i = try? container.decode(Int.self, forKey: key) { return .int(i) }
    if let d = try? container.decode(Double.self, forKey: key) { return .double(d) }
    if let s = try? container.decode(String.self, forKey: key) { return .string(s) }
    return nil
}

/// `String` target: numbers/bools are rendered the way JSON would show them
/// (`85`, `8.5`, `true`); objects/arrays degrade to `nil`.
func decodeLenient<K: CodingKey>(
    _ type: String.Type,
    forKey key: K,
    in container: KeyedDecodingContainer<K>
) -> String? {
    if let direct = try? container.decodeIfPresent(String.self, forKey: key) {
        return direct
    }
    switch lenientScalar(forKey: key, in: container) {
    case .string(let s): return s
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    case .bool(let b): return b ? "true" : "false"
    case nil: return nil
    }
}

/// `Int` target: doubles truncate, numeric strings parse exactly, bools map to
/// `0`/`1`; non-numeric strings and containers degrade to `nil`.
func decodeLenient<K: CodingKey>(
    _ type: Int.Type,
    forKey key: K,
    in container: KeyedDecodingContainer<K>
) -> Int? {
    if let direct = try? container.decodeIfPresent(Int.self, forKey: key) {
        return direct
    }
    switch lenientScalar(forKey: key, in: container) {
    case .int(let i): return i
    case .double(let d): return Int(d)
    case .bool(let b): return b ? 1 : 0
    case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
    case nil: return nil
    }
}

/// `Double` target: ints convert, numeric strings parse; else `nil`.
func decodeLenient<K: CodingKey>(
    _ type: Double.Type,
    forKey key: K,
    in container: KeyedDecodingContainer<K>
) -> Double? {
    if let direct = try? container.decodeIfPresent(Double.self, forKey: key) {
        return direct
    }
    switch lenientScalar(forKey: key, in: container) {
    case .double(let d): return d
    case .int(let i): return Double(i)
    case .bool(let b): return b ? 1 : 0
    case .string(let s): return lenientDouble(from: s)
    case nil: return nil
    }
}

/// `Bool` target: numbers map via `value != 0`; strings map by a strict
/// whitelist (`true`/`1`/`yes`/`on` → `true`; `false`/`0`/`no`/`off`/`""` →
/// `false`; any other string → `nil`); containers degrade to `nil`.
func decodeLenient<K: CodingKey>(
    _ type: Bool.Type,
    forKey key: K,
    in container: KeyedDecodingContainer<K>
) -> Bool? {
    if let direct = try? container.decodeIfPresent(Bool.self, forKey: key) {
        return direct
    }
    switch lenientScalar(forKey: key, in: container) {
    case .bool(let b): return b
    case .int(let i): return i != 0
    case .double(let d): return d != 0
    case .string(let s):
        let normalized = s.trimmingCharacters(in: .whitespaces).lowercased()
        switch normalized {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off", "": return false
        default: return nil
        }
    case nil: return nil
    }
}

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

/// Decode an array defensively: a missing key, a `null`, or a non-array value
/// all yield `[]`; individual elements that fail to decode are skipped rather
/// than aborting the whole array. A successful API response must never throw
/// because one element of a list is malformed.
func decodeArrayIfPresent<T: Decodable, K: CodingKey>(
    _ type: T.Type,
    forKey key: K,
    in container: KeyedDecodingContainer<K>
) -> [T] {
    guard var unkeyed = try? container.nestedUnkeyedContainer(forKey: key) else {
        return []
    }
    var out: [T] = []
    while !unkeyed.isAtEnd {
        let indexBefore = unkeyed.currentIndex
        // Decode each element; on failure, advance past it (decode as a throwaway
        // AnyCodable so the cursor moves) and skip rather than abort.
        if let element = try? unkeyed.decode(T.self) {
            out.append(element)
        } else {
            _ = try? unkeyed.decode(AnyCodable.self)
        }
        // Guard against a non-advancing cursor (a malformed element that neither
        // decoder consumed) — bail rather than spin forever.
        if unkeyed.currentIndex == indexBefore { break }
    }
    return out
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
        self.artistName = decodeLenient(String.self, forKey: .artistName, in: c)
        self.url = decodeLenient(String.self, forKey: .url, in: c)
        self.durationInMillis = decodeLenient(Int.self, forKey: .durationInMillis, in: c)
        self.name = decodeLenient(String.self, forKey: .name, in: c)
        self.isrc = decodeLenient(String.self, forKey: .isrc, in: c)
        self.albumName = decodeLenient(String.self, forKey: .albumName, in: c)
        self.trackNumber = decodeLenient(Int.self, forKey: .trackNumber, in: c)
        self.composerName = decodeLenient(String.self, forKey: .composerName, in: c)
        self.discNumber = decodeLenient(Int.self, forKey: .discNumber, in: c)
        self.releaseDate = decodeLenient(String.self, forKey: .releaseDate, in: c)
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
        self.id = decodeLenient(String.self, forKey: .id, in: c)
        self.name = decodeLenient(String.self, forKey: .name, in: c)
        self.durationMs = decodeLenient(Int.self, forKey: .durationMs, in: c)
        self.explicit = decodeLenient(Bool.self, forKey: .explicit, in: c)
        self.popularity = decodeLenient(Int.self, forKey: .popularity, in: c)
        self.trackNumber = decodeLenient(Int.self, forKey: .trackNumber, in: c)
        self.type = decodeLenient(String.self, forKey: .type, in: c)
        self.uri = decodeLenient(String.self, forKey: .uri, in: c)
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
        self.id = decodeLenient(Int.self, forKey: .id, in: c)
        self.title = decodeLenient(String.self, forKey: .title, in: c)
        self.duration = decodeLenient(Int.self, forKey: .duration, in: c)
        self.link = decodeLenient(String.self, forKey: .link, in: c)
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
        self.id = decodeLenient(String.self, forKey: .id, in: c)
        self.name = decodeLenient(String.self, forKey: .name, in: c)
        self.isrc = decodeLenient(String.self, forKey: .isrc, in: c)
        self.artistName = decodeLenient(String.self, forKey: .artistName, in: c)
        self.albumName = decodeLenient(String.self, forKey: .albumName, in: c)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
    }
}

public struct MusicBrainzEntry: Sendable, Equatable, Decodable {
    public let id: String?
    public let score: Int?
    public let title: String?
    public let length: Int?
    public let extras: [String: AnyCodable]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, score, title, length
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = decodeLenient(String.self, forKey: .id, in: c)
        // server may send int or string for score
        if let intScore = try? c.decode(Int.self, forKey: .score) {
            self.score = intScore
        } else if let strScore = try? c.decode(String.self, forKey: .score), let parsed = Int(strScore) {
            self.score = parsed
        } else {
            self.score = nil
        }
        self.title = decodeLenient(String.self, forKey: .title, in: c)
        self.length = decodeLenient(Int.self, forKey: .length, in: c)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
    }
}

// MARK: - RecognitionResult

public struct RecognitionResult: Sendable, Equatable, Decodable {
    public let timecode: String?
    public let audioID: Int?
    public let artist: String?
    public let title: String?
    public let album: String?
    public let releaseDate: String?
    public let label: String?
    public let songLink: String?
    public let isrc: String?
    public let upc: String?
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
        case isrc, upc
        case appleMusic = "apple_music"
        case spotify, deezer, napster, musicbrainz
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.timecode = decodeLenient(String.self, forKey: .timecode, in: c)
        self.audioID = decodeLenient(Int.self, forKey: .audioID, in: c)
        self.artist = decodeLenient(String.self, forKey: .artist, in: c)
        self.title = decodeLenient(String.self, forKey: .title, in: c)
        self.album = decodeLenient(String.self, forKey: .album, in: c)
        self.releaseDate = decodeLenient(String.self, forKey: .releaseDate, in: c)
        self.label = decodeLenient(String.self, forKey: .label, in: c)
        self.songLink = decodeLenient(String.self, forKey: .songLink, in: c)
        self.isrc = decodeLenient(String.self, forKey: .isrc, in: c)
        self.upc = decodeLenient(String.self, forKey: .upc, in: c)
        self.appleMusic = try? c.decodeIfPresent(AppleMusicMetadata.self, forKey: .appleMusic)
        self.spotify = try? c.decodeIfPresent(SpotifyMetadata.self, forKey: .spotify)
        self.deezer = try? c.decodeIfPresent(DeezerMetadata.self, forKey: .deezer)
        self.napster = try? c.decodeIfPresent(NapsterMetadata.self, forKey: .napster)
        self.musicbrainz = c.contains(.musicbrainz)
            ? decodeArrayIfPresent(MusicBrainzEntry.self, forKey: .musicbrainz, in: c)
            : nil
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
    public let score: Int?
    public let timecode: String?
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

    /// Where this song plays in the user's file, in seconds. Computed by
    /// anchoring the fragment-relative ``startOffset`` to the chunk's position
    /// in the file. `nil` when the chunk offset is absent or unparseable.
    public var startSeconds: Double?

    /// Where this song stops playing in the user's file, in seconds. Computed
    /// by anchoring the fragment-relative ``endOffset`` to the chunk's position
    /// in the file. `nil` when the chunk offset is absent or unparseable.
    public var endSeconds: Double?

    public let extras: [String: AnyCodable]
    public let rawResponse: AnyCodable

    // `startSeconds`/`endSeconds` are computed locally from the enclosing
    // chunk's `offset` after decoding — they are deliberately excluded from
    // `CodingKeys` so decoding never expects them on the wire.
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
        self.score = decodeLenient(Int.self, forKey: .score, in: c)
        self.timecode = decodeLenient(String.self, forKey: .timecode, in: c)
        self.artist = decodeLenient(String.self, forKey: .artist, in: c)
        self.title = decodeLenient(String.self, forKey: .title, in: c)
        self.album = decodeLenient(String.self, forKey: .album, in: c)
        self.releaseDate = decodeLenient(String.self, forKey: .releaseDate, in: c)
        self.label = decodeLenient(String.self, forKey: .label, in: c)
        self.isrc = decodeLenient(String.self, forKey: .isrc, in: c)
        self.upc = decodeLenient(String.self, forKey: .upc, in: c)
        self.songLink = decodeLenient(String.self, forKey: .songLink, in: c)
        self.startOffset = decodeLenient(Int.self, forKey: .startOffset, in: c)
        self.endOffset = decodeLenient(Int.self, forKey: .endOffset, in: c)
        self.startSeconds = nil
        self.endSeconds = nil
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

/// Parse a chunk `offset` into seconds. Accepts `"SS"`, `"MM:SS"`,
/// `"HH:MM:SS"`, or a bare number (string or already-numeric). Returns `nil`
/// for `nil`/empty/unparseable input — never throws.
func offsetToSeconds(_ offset: String?) -> Double? {
    guard let offset, !offset.isEmpty else { return nil }
    let trimmed = offset.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
    switch parts.count {
    case 1:
        return Double(parts[0])
    case 2:
        guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
        return m * 60 + s
    case 3:
        guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    default:
        return nil
    }
}

struct EnterpriseChunkResult: Decodable {
    let songs: [EnterpriseMatch]
    let offset: String?

    enum CodingKeys: String, CodingKey {
        case songs, offset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.songs = decodeArrayIfPresent(EnterpriseMatch.self, forKey: .songs, in: c)
        self.offset = decodeLenient(String.self, forKey: .offset, in: c)
    }
}

// MARK: - Streams

public struct Stream: Sendable, Equatable, Decodable {
    public let radioID: Int?
    public let url: String?
    public let streamRunning: Bool?
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
        self.radioID = decodeLenient(Int.self, forKey: .radioID, in: c)
        self.url = decodeLenient(String.self, forKey: .url, in: c)
        self.streamRunning = decodeLenient(Bool.self, forKey: .streamRunning, in: c)
        self.longpollCategory = decodeLenient(String.self, forKey: .longpollCategory, in: c)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
        self.rawResponse = try decodeRawResponse(from: decoder)
    }
}

/// One candidate song in a stream-callback / longpoll recognition match. Almost
/// every match has exactly one song; multiple candidates only appear when the
/// same fingerprint resolves to several near-identical catalog records.
public struct StreamCallbackSong: Sendable, Equatable, Decodable {
    public let score: Int?
    public let artist: String?
    public let title: String?
    public let album: String?
    public let releaseDate: String?
    public let label: String?
    public let songLink: String?
    public let isrc: String?
    public let upc: String?
    public let appleMusic: AppleMusicMetadata?
    public let spotify: SpotifyMetadata?
    public let deezer: DeezerMetadata?
    public let napster: NapsterMetadata?
    public let musicbrainz: [MusicBrainzEntry]?
    public let extras: [String: AnyCodable]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case score, artist, title, album
        case releaseDate = "release_date"
        case label
        case songLink = "song_link"
        case isrc, upc
        case appleMusic = "apple_music"
        case spotify, deezer, napster, musicbrainz
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.score = decodeLenient(Int.self, forKey: .score, in: c)
        self.artist = decodeLenient(String.self, forKey: .artist, in: c)
        self.title = decodeLenient(String.self, forKey: .title, in: c)
        self.album = decodeLenient(String.self, forKey: .album, in: c)
        self.releaseDate = decodeLenient(String.self, forKey: .releaseDate, in: c)
        self.label = decodeLenient(String.self, forKey: .label, in: c)
        self.songLink = decodeLenient(String.self, forKey: .songLink, in: c)
        self.isrc = decodeLenient(String.self, forKey: .isrc, in: c)
        self.upc = decodeLenient(String.self, forKey: .upc, in: c)
        self.appleMusic = try? c.decodeIfPresent(AppleMusicMetadata.self, forKey: .appleMusic)
        self.spotify = try? c.decodeIfPresent(SpotifyMetadata.self, forKey: .spotify)
        self.deezer = try? c.decodeIfPresent(DeezerMetadata.self, forKey: .deezer)
        self.napster = try? c.decodeIfPresent(NapsterMetadata.self, forKey: .napster)
        self.musicbrainz = c.contains(.musicbrainz)
            ? decodeArrayIfPresent(MusicBrainzEntry.self, forKey: .musicbrainz, in: c)
            : nil
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
    }
}

/// One recognition event from a stream callback or longpoll.
///
/// Carries the top match in ``song``; rare extra candidates live in
/// ``alternatives``. Entries in ``alternatives`` may have a different
/// `artist`/`title` than ``song`` — this happens with variant catalog
/// releases (e.g. "single" vs "album" recordings, regional re-releases,
/// near-duplicate fingerprints across labels).
public struct StreamCallbackMatch: Sendable, Equatable, Decodable {
    public let radioID: Int?
    public let timestamp: String?
    public let playLength: Int?

    /// The top match. `nil` when the callback carries an empty `results` array —
    /// parsing never throws on a missing/empty match.
    public let song: StreamCallbackSong?

    /// Additional candidate songs. Empty in the common case. Entries may have
    /// a different `artist`/`title` than ``song`` (variant catalog releases).
    public let alternatives: [StreamCallbackSong]

    public let extras: [String: AnyCodable]
    public let rawResponse: AnyCodable?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case radioID = "radio_id"
        case timestamp
        case playLength = "play_length"
        case results
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.radioID = decodeLenient(Int.self, forKey: .radioID, in: c)
        self.timestamp = decodeLenient(String.self, forKey: .timestamp, in: c)
        self.playLength = decodeLenient(Int.self, forKey: .playLength, in: c)
        let results = decodeArrayIfPresent(StreamCallbackSong.self, forKey: .results, in: c)
        self.song = results.first
        self.alternatives = Array(results.dropFirst())
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
        self.rawResponse = nil
    }

    /// Internal initializer used by ``parseCallback(_:)`` to attach the raw
    /// outer-callback bytes (which include the wrapping `{"result": ...}`).
    init(
        radioID: Int?,
        timestamp: String?,
        playLength: Int?,
        song: StreamCallbackSong?,
        alternatives: [StreamCallbackSong],
        extras: [String: AnyCodable],
        rawResponse: AnyCodable?
    ) {
        self.radioID = radioID
        self.timestamp = timestamp
        self.playLength = playLength
        self.song = song
        self.alternatives = alternatives
        self.extras = extras
        self.rawResponse = rawResponse
    }
}

/// The lifecycle-event variant of a stream callback (e.g. "stream stopped",
/// "can't connect"). Distinct from a recognition match.
public struct StreamCallbackNotification: Sendable, Equatable, Decodable {
    public let radioID: Int?
    public let streamRunning: Bool?
    public let notificationCode: Int?
    public let notificationMessage: String?

    /// Outer `time` field on the callback envelope. Server-supplied unix
    /// timestamp; absent on inner-only fixtures or some longpoll envelopes.
    public let time: Int?

    public let extras: [String: AnyCodable]
    public let rawResponse: AnyCodable?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case radioID = "radio_id"
        case streamRunning = "stream_running"
        case notificationCode = "notification_code"
        case notificationMessage = "notification_message"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.radioID = decodeLenient(Int.self, forKey: .radioID, in: c)
        self.streamRunning = decodeLenient(Bool.self, forKey: .streamRunning, in: c)
        self.notificationCode = decodeLenient(Int.self, forKey: .notificationCode, in: c)
        self.notificationMessage = decodeLenient(String.self, forKey: .notificationMessage, in: c)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
        self.time = nil
        self.rawResponse = nil
    }

    /// Internal initializer used by ``parseCallback(_:)`` to attach the outer
    /// `time` field and the raw outer-callback bytes.
    init(
        radioID: Int?,
        streamRunning: Bool?,
        notificationCode: Int?,
        notificationMessage: String?,
        time: Int?,
        extras: [String: AnyCodable],
        rawResponse: AnyCodable?
    ) {
        self.radioID = radioID
        self.streamRunning = streamRunning
        self.notificationCode = notificationCode
        self.notificationMessage = notificationMessage
        self.time = time
        self.extras = extras
        self.rawResponse = rawResponse
    }
}

/// The result of parsing a stream callback or longpoll envelope. Exactly one
/// case populated.
public enum CallbackEvent: Sendable, Equatable {
    case match(StreamCallbackMatch)
    case notification(StreamCallbackNotification)
}

// MARK: - Lyrics

public struct LyricsResult: Sendable, Equatable, Decodable {
    public let artist: String?
    public let title: String?
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
        self.artist = decodeLenient(String.self, forKey: .artist, in: c)
        self.title = decodeLenient(String.self, forKey: .title, in: c)
        self.lyrics = decodeLenient(String.self, forKey: .lyrics, in: c)
        self.songID = decodeLenient(Int.self, forKey: .songID, in: c)
        self.media = decodeLenient(String.self, forKey: .media, in: c)
        self.fullTitle = decodeLenient(String.self, forKey: .fullTitle, in: c)
        self.artistID = decodeLenient(Int.self, forKey: .artistID, in: c)
        self.songLink = decodeLenient(String.self, forKey: .songLink, in: c)
        self.extras = try decodeExtras(from: decoder, knownKeys: CodingKeys.self)
        self.rawResponse = try decodeRawResponse(from: decoder)
    }
}
