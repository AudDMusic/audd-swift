# AudD

Official Swift package for [AudD](https://audd.io) — music recognition from a short audio clip, a long audio file, or a live stream.

The [API itself](https://docs.audd.io) is so simple that it can be easily used even without an SDK.

**Platforms:** iOS 15+, macOS 12+, watchOS 8+, tvOS 15+, visionOS 1+, Linux. Swift 5.9+, builds clean under Swift 6 strict-concurrency mode.

## Quickstart

`Package.swift`:

```swift
.package(url: "https://github.com/AudDMusic/audd-swift", from: "1.4.5"),
```

Get your API token at [dashboard.audd.io](https://dashboard.audd.io).

Add `"AudD"` to your target's `dependencies`, then recognize from a URL:

```swift
import AudD

let audd = try AudD(apiToken: "test")
if let result = try await audd.recognize("https://audd.tech/example.mp3") {
    print("\(result.artist ?? "?") — \(result.title ?? "?")")
}
```

Recognize from a local file:

```swift
import AudD
import Foundation

let audd = try AudD(apiToken: "test")
let file = URL(fileURLWithPath: "/path/to/clip.mp3")
if let result = try await audd.recognize(.file(file)) {
    print("\(result.artist ?? "?") — \(result.title ?? "?")")
}
```

`Source` accepts `.url(URL)`, `.file(URL)`, `.data(Data)`, or `.stream(InputStream, name:)`.
`recognize` returns `RecognitionResult?` — `nil` when the clip isn't recognized
(distinct from a thrown error).

For files longer than 25 seconds (broadcasts, podcasts, full DJ sets), use
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

let audd = try AudD(apiToken: "test")
guard let result = try await audd.recognize("https://audd.tech/example.mp3") else {
    print("no match")
    return
}

// Core tags
print(result.artist ?? "", "—", result.title ?? "")
print(result.album ?? "", result.releaseDate ?? "", result.label ?? "")

// AudD's universal song page — links into every provider
print(result.songLink ?? "")

// Helpers — driven off songLink, work without any `return` opt-in
print(result.thumbnailURL ?? "")            // cover-art URL, or nil
print(result.streamingUrl(.spotify) ?? "")  // direct or lis.tn redirect, or nil
print(result.streamingUrls())               // [.spotify: "...", .deezer: "...", ...]
```

If you need provider-specific metadata blocks, opt in per call. Request only what you need — each provider you ask for adds latency:

```swift
guard let result = try await audd.recognize(
    "https://audd.tech/example.mp3",
    return: ["apple_music", "spotify"]
) else { return }

print(result.appleMusic?.url ?? "")  // direct Apple Music link
print(result.spotify?.uri ?? "")     // spotify:track:...
print(result.previewUrl() ?? "")     // first preview across requested providers, nil if none
```

Valid `return` values: `apple_music`, `spotify`, `deezer`, `napster`,
`musicbrainz`. The corresponding properties (`appleMusic`, `spotify`, …) are
`nil` when not requested.

`EnterpriseMatch` (returned by `recognizeEnterprise`) carries the same core
tags plus `score`, `startOffset`, `endOffset`, `isrc`, `upc`. Access to
`isrc`, `upc`, and `score` requires a Startup plan or higher — [contact
us](mailto:api@audd.io) for enterprise features.

## Reading additional metadata

The typed models cover what AudD documents. To read undocumented or beta
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

The callback receives JSON; parse it into a typed payload:

```swift
// In your webhook handler, given the parsed JSON `body: [String: Any]`:
let payload = try await audd.streams.parseCallback(body)
if payload.isResult, let result = payload.result {
    for entry in result.results {
        print(entry.artist, "—", entry.title, "score=", entry.score)
    }
} else if payload.isNotification, let notification = payload.notification {
    print("notification:", notification.notificationMessage)
}
```

### Longpoll

If you can't expose a public callback URL, longpoll instead. AudD still
requires a callback URL to be configured for the account
(`https://audd.tech/empty/` works as a no-op receiver), and the SDK
preflights this for you — pass `skipCallbackCheck: true` to skip if you've
already verified.

```swift
let streams = await audd.streams
let category = streams.deriveLongpollCategory(radioID: 42)

for try await event in streams.longpoll(category: category, timeout: 30) {
    print(event)  // [String: AnyCodable] — same shape as a callback payload
}
```

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

for try await event in consumer.iterate(timeout: 30) {
    print(event)
}
```

`LongpollConsumer` carries no api_token. The category alone authorizes the
subscription.

## Documentation

Full DocC reference ships with the SDK at
[`Sources/AudD/AudD.docc/`](./Sources/AudD/AudD.docc/) — articles for
recognition, streams, errors, and streaming-helper resolution rules, plus
symbol-level docs for every public type. Build it locally:

```bash
swift package generate-documentation --target AudD
```

Or open the rendered docs on the [Swift Package Index](https://swiftpackageindex.com/AudDMusic/audd-swift/documentation)
once the package is registered there.

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

Runnable end-to-end examples live under [`Examples/`](./Examples/) and build
with `swift run <target>`.
