# ``AudD``

Official Swift SDK for the AudD music recognition API.

## Overview

`AudD` provides an idiomatic, async/await Swift client for the
[AudD](https://audd.io) music recognition API: recognize music from URLs,
files, raw bytes, or streams; manage live audio-stream subscriptions; receive
real-time events via webhook callbacks or longpoll; and search lyrics.

The SDK is data-race-free and Swift 6 strict-concurrency clean. The top-level
client is an `actor`; every public model and helper conforms to `Sendable`.

### Hello, world

```swift
import AudD

let audd = try AudD(apiToken: "your-api-token")
defer { Task { await audd.close() } }

if let result = try await audd.recognize("https://audd.tech/example.mp3") {
    print("\(result.artist ?? "?") — \(result.title ?? "?")")
} else {
    print("No match")
}
```

`AudD(apiToken:)` reads `AUDD_API_TOKEN` from the environment when called with
`nil` or an empty string. ``AudD/fromEnvironment(maxRetries:backoffFactor:urlSession:enterpriseURLSession:apiBase:enterpriseBase:onEvent:)``
is a convenience factory for the env-var path.

### Capabilities

- **Recognition** — ``AudD/recognize(_:return:market:)-7jkwp`` for short
  files (≤ 25 s); ``AudD/recognizeEnterprise(_:return:skip:every:limit:skipFirstSeconds:useTimecode:accurateOffsets:)``
  for arbitrarily long files.
- **Custom catalog** — ``CustomCatalog/add(audioID:source:)`` adds songs to your
  private fingerprint database. Enterprise access required; this is **not**
  for music recognition.
- **Streams** — subscribe live audio streams and receive recognition events:
  ``Streams/add(url:radioID:callbacks:)``, ``Streams/longpoll(category:options:)``,
  ``Streams/parseCallback(_:)``.
- **Lyrics** — ``Advanced/findLyrics(_:)``.
- **Inspection hook** — ``AudDEvent`` lifecycle events delivered to an opt-in
  `onEvent` callback for tracing.
- **Forward-compatible models** — every model exposes typed fields plus an
  `extras` dictionary and `rawResponse` for unknown keys.
- **Cost-aware retry** — recognition endpoints don't retry post-upload read
  timeouts (cost protection); mutating endpoints don't retry on 5xx (the side
  effect may have happened).

### Concurrency

- ``AudD`` is an `actor`. All methods are `async`. State (api_token, retry
  policy, sessions) is actor-isolated.
- Every model and namespace (``Streams``, ``CustomCatalog``, ``Advanced``)
  conforms to `Sendable`.
- The `onEvent` hook is `@Sendable (AudDEvent) -> Void`.
- Build with `-strict-concurrency=complete` or Swift 6 mode without changes.

## Topics

### Articles

- <doc:Recognition>
- <doc:Streams>
- <doc:Errors>
- <doc:StreamingHelpers>

### Top-level client

- ``AudD``

### Recognition

- ``Source``
- ``RecognitionResult``
- ``EnterpriseMatch``
- ``StreamingProvider``

### Recognition metadata blocks

- ``AppleMusicMetadata``
- ``SpotifyMetadata``
- ``DeezerMetadata``
- ``NapsterMetadata``
- ``MusicBrainzEntry``

### Streams

- ``Streams``
- ``Stream``
- ``CallbackEvent``
- ``StreamCallbackMatch``
- ``StreamCallbackSong``
- ``StreamCallbackNotification``
- ``LongpollPoll``
- ``LongpollOptions``
- ``LongpollConsumer``

### Custom catalog and advanced

- ``CustomCatalog``
- ``Advanced``
- ``LyricsResult``

### Errors

- ``AudDError``
- ``AudDErrorKind``
- ``AudDAPIErrorDetail``

### Observability

- ``AudDEvent``
- ``AudDEventHook``

### Retry policy

- ``RetryPolicy``
- ``RetryClass``

### Forward-compat extras

- ``AnyCodable``
