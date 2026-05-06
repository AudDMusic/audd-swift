# Recognition

Recognize music from URLs, files, raw bytes, or input streams.

## Overview

The SDK exposes two recognition endpoints:

- ``AudD/recognize(_:return:market:)-7jkwp`` — the standard endpoint. Files up
  to ~25 seconds (server-side limit); short clips of YouTube/Spotify/etc. by
  URL also work.
- ``AudD/recognizeEnterprise(_:return:skip:every:limit:skipFirstSeconds:useTimecode:accurateOffsets:)``
  — the enterprise endpoint. No length limit; chunks the input server-side and
  returns one or more matches. Default `limit: 1`.

Both accept a ``Source`` value:

- `.url(URL)` — the AudD server fetches it. No bytes upload from your side.
- `.file(URL)` — local file path; the SDK reads bytes per attempt.
- `.data(Data)` — raw bytes already in memory.
- `.stream(InputStream, name:)` — read once, buffered for retry.

### Recognize a public URL

```swift
let audd = try AudD(apiToken: "your-api-token")
defer { Task { await audd.close() } }

if let result = try await audd.recognize("https://audd.tech/example.mp3") {
    print("\(result.artist ?? "?") — \(result.title ?? "?")")
    print("Timecode: \(result.timecode)")
}
```

### Recognize a local file

```swift
let url = URL(fileURLWithPath: "/path/to/clip.mp3")
let result = try await audd.recognize(.file(url))
```

### Recognize raw bytes

```swift
let bytes: Data = ...
let result = try await audd.recognize(.data(bytes))
```

### Request streaming-provider metadata

Pass `return:` with a list of providers:

```swift
let result = try await audd.recognize(
    .url(URL(string: "https://audd.tech/example.mp3")!),
    return: ["apple_music", "spotify", "deezer"]
)
print(result?.appleMusic?.url ?? "no apple music URL")
```

### Enterprise recognition (long files)

Enterprise responses come back as `[EnterpriseMatch]`. A `limit: 1` is set by
default; raise it if you need multiple matches.

```swift
let matches = try await audd.recognizeEnterprise(
    .file(URL(fileURLWithPath: "/path/to/long.mp3")),
    return: ["isrc", "upc"],
    limit: 5
)
for match in matches {
    print("\(match.artist ?? "?") — \(match.title ?? "?") @ \(match.timecode)")
}
```

### Forward-compatible fields

Every recognition model includes:

- typed fields (``RecognitionResult/artist``, ``RecognitionResult/title``,
  etc.) for the keys we know about today,
- ``RecognitionResult/extras`` — any unknown keys, as
  `[String: AnyCodable]`,
- ``RecognitionResult/rawResponse`` — the full server payload.

This means the SDK ships forward-compatible: when AudD adds a new field, your
code can read it from `extras` without an SDK upgrade.

## Topics

### Sources

- ``Source``

### Result types

- ``RecognitionResult``
- ``EnterpriseMatch``

### Streaming-provider helpers

- <doc:StreamingHelpers>
