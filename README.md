# audd-swift

[![Powered by AudD](https://img.shields.io/badge/Music_Recognition-AudD_API-2a4eef)](https://audd.io)
[![CI](https://github.com/AudDMusic/audd-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/AudDMusic/audd-swift/actions/workflows/ci.yml)
[![Contract](https://github.com/AudDMusic/audd-swift/actions/workflows/contract.yml/badge.svg)](https://github.com/AudDMusic/audd-swift/actions/workflows/contract.yml)
[![Swift Version Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FAudDMusic%2Faudd-swift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/AudDMusic/audd-swift)
[![Platform Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FAudDMusic%2Faudd-swift%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/AudDMusic/audd-swift)

Official Swift package for [music recognition API](https://audd.io): identify music from a short audio clip, a long audio file, or a live stream.

The API itself is so simple that it can easily be used even without an SDK: [docs.audd.io](https://docs.audd.io).

**Platforms:** iOS 15+, macOS 12+, watchOS 8+, tvOS 15+, visionOS 1+, Linux. Swift 5.9+.

## Quickstart

`Package.swift`:

```swift
.package(url: "https://github.com/AudDMusic/audd-swift", from: "1.5.17"),
```

Get your API token at [dashboard.audd.io](https://dashboard.audd.io).

Add `"AudD"` to your target's `dependencies`, then recognize from a URL:

```swift
import AudD

let audd = try AudD(apiToken: "your-api-token")
if let result = try await audd.recognize("https://audd.tech/example.mp3") {
    print("\(result.artist ?? "?") — \(result.title ?? "?")")
}
```

Recognize from a local file:

```swift
import AudD
import Foundation

let audd = try AudD(apiToken: "your-api-token")
let file = URL(fileURLWithPath: "/path/to/clip.mp3")
if let result = try await audd.recognize(.file(file)) {
    print("\(result.artist ?? "?") — \(result.title ?? "?")")
}
```

`Source` accepts `.url(URL)`, `.file(URL)`, `.data(Data)`, or `.stream(InputStream, name:)`.
`recognize` returns `RecognitionResult?` — `nil` when the clip isn't recognized
(distinct from a thrown error).

For longer audio files (full-length songs, short-form videos, podcasts, broadcasts, DJ sets), use
`recognizeEnterprise(_:limit:...)` — it returns `[EnterpriseMatch]`, one per
song detected across the file.

## Authentication

Pass the token as a literal string:

```swift
let audd = try AudD(apiToken: "your-token")
```

Or omit it (or pass `nil` / `""`) to read `AUDD_API_TOKEN` from the
environment. `AudD.fromEnvironment()` is a convenience factory for that path:

```swift
let audd = try AudD.fromEnvironment()
```

For long-running services that rotate tokens (e.g., from a secret manager),
call `await audd.setApiToken(newToken)`. In-flight requests finish on the
previous token; subsequent requests use the new one.

## What you get back

By default `recognize` returns the core tags plus AudD's universal song link — no metadata-block opt-in needed:

```swift
import AudD

let audd = try AudD(apiToken: "your-api-token")
guard let result = try await audd.recognize("https://audd.tech/example.mp3") else {
    print("no match")
    return
}

// Core tags
print(result.artist ?? "", "—", result.title ?? "")
print(result.album ?? "", result.releaseDate ?? "", result.label ?? "")

// AudD's universal song page — links into every provider
print(result.songLink ?? "")

// Helpers — driven off songLink, work without any `returnMetadata` opt-in
print(result.thumbnailURL ?? "")            // cover-art URL, or nil
print(result.streamingUrl(.spotify) ?? "")  // direct or lis.tn redirect, or nil
print(result.streamingUrls())               // [.spotify: "...", .deezer: "...", ...]
```

If you need provider-specific metadata blocks, opt in per call. Request only what you need — each provider you ask for adds latency:

```swift
guard let result = try await audd.recognize(
    "https://audd.tech/example.mp3",
    returnMetadata: ["apple_music", "spotify"]
) else { return }

print(result.appleMusic?.url ?? "")  // direct Apple Music link
print(result.spotify?.uri ?? "")     // spotify:track:...
print(result.previewUrl() ?? "")     // first preview across requested providers, nil if none
```

Valid `returnMetadata` values: `apple_music`, `spotify`, `deezer`, `napster`,
`musicbrainz`. The corresponding properties (`appleMusic`, `spotify`, …) are
`nil` when not requested.

`EnterpriseMatch` (returned by `recognizeEnterprise`) carries the same core
tags plus `score`, `isrc`, `upc`, and `startSeconds` / `endSeconds` — where the
song plays in your file, in seconds. These are precise because
`recognizeEnterprise` requests accurate offsets by default (pass
`accurateOffsets: false` to opt out). The raw fragment-relative `startOffset` /
`endOffset` (milliseconds within the matched fragment) sit behind them. Access
to `isrc`, `upc`, and `score` requires a Startup plan or higher — [contact
us](mailto:api@audd.io) for enterprise features.

## Reading additional metadata

The typed models cover what AudD's typed surface covers. To read additional
fields the server returns, go through `extras` (per-model) or `rawResponse`
(full payload):

```swift
// Top-level extras — anything outside the typed surface
let genre = result.extras["genre"]?.value as? String

// Nested extras inside a typed metadata block
let artwork = result.appleMusic?.extras["artwork"]?.value

// Or the full untyped payload
let raw = result.rawResponse.value
```

This is the supported API for fields outside the typed surface. Beta features
and per-account custom fields show up here.

For sending arbitrary form fields the typed parameters don't cover, pass an
`extraParameters` map:

```swift
let result = try await audd.recognize(
    .file(URL(fileURLWithPath: "/tmp/snippet.wav")),
    returnMetadata: ["apple_music"],
    extraParameters: ["my_custom_flag": "1"]
)
```

Typed parameters win on collision.

## Errors

Every server-side error becomes a typed `AudDError` case. Pattern-match on the
case (and on `detail.kind` for API errors) to handle whole families:

```swift
import AudD

do {
    _ = try await audd.recognize("https://example.mp3")
} catch let AudDError.api(detail) where detail.kind == .authentication {
    // 900 / 901 / 903
    print("check your token: [#\(detail.errorCode)] \(detail.message)")
} catch let AudDError.api(detail) where detail.kind == .invalidAudio {
    // 300 / 400 / 500
    print("audio rejected: \(detail.message)")
} catch let AudDError.api(detail) {
    // Catch-all for anything the server reported
    print("AudD #\(detail.errorCode): \(detail.message) (request_id=\(detail.requestID ?? "-"))")
} catch AudDError.connection(let message, _) {
    // network / TLS / timeout — no HTTP response received
    print("connection: \(message)")
} catch AudDError.serverError(let status, let message, _, _) {
    // non-2xx with non-JSON body (gateway HTML, timeout text, etc.)
    print("server error HTTP \(status): \(message)")
} catch AudDError.serializationError(let message, _) {
    // 2xx with malformed JSON
    print("decode: \(message)")
}
```

The `AudDErrorKind` enum maps the AudD numeric error catalog to families:
`.authentication`, `.quota`, `.subscription`, `.customCatalogAccess`,
`.invalidRequest`, `.invalidAudio`, `.rateLimit`, `.streamLimit`,
`.notReleased`, `.blocked`, `.needsUpdate`, `.server`. Every
`AudDAPIErrorDetail` carries `errorCode`, `message`, `httpStatus`,
`requestID`, `requestedParams`, `requestMethod`, `brandedMessage`, and
`rawResponse` — enough to log a full incident or open a support ticket.

## Configuration

```swift
import AudD
import Foundation

let session = URLSession(configuration: .ephemeral)

let audd = try AudD(
    apiToken: "your-token",
    maxRetries: 3,                       // per-call retry budget
    backoffFactor: 0.5,                  // initial backoff seconds (jittered)
    urlSession: session,                 // inject your own URLSession
    enterpriseURLSession: session,       // separate session for the enterprise endpoint (optional)
    onEvent: { event in                  // tracing / metrics hook
        print(event.kind, event.method, event.requestId ?? "-")
    }
)
```

**Custom URLSession.** Inject your own `URLSession` to add a custom
configuration, proxy, certificate pinning, or shared connection pool. The SDK
adds its `User-Agent` header. The enterprise endpoint can optionally use a
separate session — useful when you want a longer resource timeout for
multi-hour file processing without affecting your standard-endpoint timeouts.

**Retries.** Calls are classified by cost and retried accordingly:

| Class | Endpoints | Retried on |
|---|---|---|
| Recognition | `recognize`, `recognizeEnterprise`, `advanced.*` | network errors and 5xx **before** the upload reaches the server |
| Read | `streams.list`, `streams.getCallbackURL`, longpoll | network errors and 5xx |
| Mutating | `streams.setCallbackURL`, `streams.add`, `streams.delete`, `customCatalog.add` | network errors and 5xx (idempotent on the server) |

Recognition will not double-bill your account: once the server has accepted
bytes, a 5xx after that is surfaced rather than retried.

**Inspection.** Pass `onEvent:` to receive an `AudDEvent` for every request /
response / exception — useful for metrics, tracing, or dropping a `requestID`
into your logs. Events never carry the api_token or request bytes; exceptions
raised from the hook are swallowed so observability can't break the request
path.

**Concurrency.** The client is an `actor` — share one instance across tasks
and structured-concurrency contexts; every method is `async` and serializes
through the actor. Token rotation via `setApiToken(_:)` takes effect on the
next outbound request; in-flight requests finish on the previous token. All
public model types and namespaces are `Sendable`.

**Lifecycle.** Call `await audd.close()` to release the underlying
`URLSession`s eagerly. `deinit` also closes; explicit close is only needed
when you want determinism (CLI tools, tests).

## Streams

Real-time recognition off radio streams, broadcast feeds, and any other
long-running URL. Configure once, then either receive callbacks on your server
or poll for events.

```swift
try await audd.streams.setCallbackURL("https://your.server/audd-callback")
try await audd.streams.add(url: "https://your.stream.url/listen.m3u8", radioID: 42)

for stream in try await audd.streams.list() {
    print(stream.radioID, stream.url, stream.streamRunning)
}
```

The callback POSTs raw bytes; parse them into a typed match or notification:

```swift
// In your webhook handler, given the raw POST body as `Data`:
switch try audd.streams.parseCallback(bodyData) {
case .match(let match):
    print("\(match.song?.artist ?? "?") — \(match.song?.title ?? "?")  score=\(match.song?.score ?? 0)")
    for alt in match.alternatives {
        // alternatives may have a different artist/title — variant catalog releases
        print("  alt: \(alt.artist ?? "?") — \(alt.title ?? "?")")
    }
case .notification(let n):
    print("notification:", n.notificationMessage ?? "?")
}
```

`parseCallback(_:)` is a pure function — no network. Use it inside whichever
HTTP framework receives your AudD callbacks (Vapor, Hummingbird, hand-rolled
URLSession listener, queue replay tool, etc.).

#### Per-framework wiring

**Vapor**:

```swift
import Vapor
import AudD

func routes(_ app: Application) throws {
    let audd = try AudD(apiToken: Environment.get("AUDD_API_TOKEN")!)
    app.post("audd", "callback") { req async throws -> HTTPStatus in
        let body = try req.content.decode(Data.self)
        let event = try audd.streams.parseCallback(body)
        switch event {
        case .match(let m):       req.logger.info("\(m.song?.artist ?? "?") — \(m.song?.title ?? "?")")
        case .notification(let n): req.logger.info("\(n.notificationMessage ?? "?")")
        }
        return .ok
    }
}
```

**Hummingbird**:

```swift
import Hummingbird
import AudD

let audd = try AudD(apiToken: ProcessInfo.processInfo.environment["AUDD_API_TOKEN"]!)
let router = Router()
router.post("/audd/callback") { req, ctx -> HTTPResponse.Status in
    let body = try await Data(buffer: req.body.collect(upTo: 1 << 20))
    let event = try audd.streams.parseCallback(body)
    // handle event.match / event.notification
    return .ok
}
```

### Longpoll

If you can't expose a public callback URL, longpoll instead. AudD still
requires a callback URL to be configured for the account
(`https://audd.tech/empty/` works as a no-op receiver), and the SDK
preflights this for you — pass `LongpollOptions(skipCallbackCheck: true)` to
skip if you've already verified.

`longpoll(...)` returns a `LongpollPoll` with three typed `AsyncStream`s —
matches, notifications, and a single-shot errors stream. Iterate the ones you
care about (often concurrently in a `withTaskGroup`):

```swift
let streams = await audd.streams
let radioID = 1 // any integer you choose — your handle for this stream

let poll = try await streams.longpoll(radioID: radioID)
defer { Task { await poll.close() } }

for await match in poll.matches {
    print("\(match.song?.artist ?? "?") — \(match.song?.title ?? "?")")
}
```

A terminal failure (HTTP 5xx, malformed JSON, connection drop after retries)
fires once on `poll.errors` and then closes all three streams.

`deriveLongpollCategory` is a local computation: `MD5(MD5(apiToken) + radioID)[..9]`.
The category alone is sufficient to subscribe — the api_token is never sent
over the wire for longpolls.

#### Tokenless consumers

For browser widgets, embedded extensions, or any context where shipping the
api_token would leak it: derive the category server-side, ship only the
category to the consumer, and have the consumer use `LongpollConsumer`:

```swift
import AudD

// `category` was derived on your server and shared with this process.
let consumer = LongpollConsumer(category: "abc123def")
defer { consumer.close() }

let poll = consumer.iterate()
defer { Task { await poll.close() } }

for await match in poll.matches {
    print("\(match.song?.artist ?? "?") — \(match.song?.title ?? "?")")
}
```

`LongpollConsumer` carries no api_token. The category alone authorizes the
subscription. The returned `LongpollPoll` exposes the same
`matches` / `notifications` / `errors` streams as the authenticated path.

## Documentation

Full DocC reference ships with the SDK at
[`Sources/AudD/AudD.docc/`](./Sources/AudD/AudD.docc/) — articles for
recognition, streams, errors, and streaming-helper resolution rules, plus
symbol-level docs for every public type. Build it locally:

```bash
swift package generate-documentation --target AudD
```

## Custom catalog (advanced)

> **The custom-catalog endpoint is NOT how you submit audio for music recognition.**
> For recognition, use `recognize` (or `recognizeEnterprise` for files longer
> than 25 seconds). The custom-catalog endpoint adds songs to your *private*
> fingerprint database so future `recognize` calls on your account can
> identify *your own* tracks.
> Requires special access — contact api@audd.io.

```swift
try await audd.customCatalog.add(audioID: 42, source: .url(URL(string: "https://my.song.mp3")!))
```

## License

MIT — see [LICENSE](./LICENSE).

## Support

- Documentation: <https://docs.audd.io>
- Tokens: <https://dashboard.audd.io>
- Issues: <https://github.com/AudDMusic/audd-swift/issues>
- Email: api@audd.io

Runnable end-to-end examples live under [`Examples/`](./Examples/) as a
sibling SwiftPM package — kept separate from the SDK proper so consumers
don't pull in CLI executables they'll never use:

```sh
cd Examples
swift run RecognizeUrl
```
