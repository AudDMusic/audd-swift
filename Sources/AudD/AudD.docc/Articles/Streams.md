# Streams

Subscribe live audio streams; receive recognition events via webhook callback
or longpoll.

## Overview

A *stream subscription* tells AudD to listen to your radio/podcast/live URL
and call you when a song is recognized. Set a callback URL once per account,
add streams as you need them, and receive events.

### One-time setup: set the callback URL

```swift
let audd = try AudD(apiToken: "your-api-token")
defer { Task { await audd.close() } }

try await audd.streams.setCallbackURL("https://your-server.example/audd-webhook")
```

If you only want longpolling and don't need a real receiver, set
`https://audd.tech/empty/`. AudD requires a callback URL on file before
longpolling will deliver events.

### Add a stream

```swift
try await audd.streams.add(
    url: "https://radio.example/stream.mp3",
    radioID: 42
)
```

### Receive callbacks (server-side)

When a song is matched, AudD POSTs to your callback URL. Parse the raw POST
body with ``Streams/parseCallback(_:)``:

```swift
// Inside your HTTP handler, given the raw POST body as `Data`:
switch try audd.streams.parseCallback(bodyData) {
case .match(let match):
    print("\(match.song.artist) — \(match.song.title)")
    for alt in match.alternatives {
        // alternatives may have different artist/title — variant releases
        print("  alt: \(alt.artist) — \(alt.title)")
    }
case .notification(let n):
    print("Stream event: \(n.notificationMessage)")
}
```

### Longpoll (no receiver needed)

Subscribe to events by polling — useful for clients that can't expose an HTTP
endpoint. ``Streams/longpoll(category:options:)`` returns a ``LongpollPoll``
with three typed `AsyncStream`s:

```swift
let category = audd.streams.deriveLongpollCategory(radioID: 42)
let poll = try await audd.streams.longpoll(category: category)
defer { Task { await poll.close() } }

for await match in poll.matches {
    print("\(match.song.artist) — \(match.song.title)")
}
```

Run `for await ...` loops on `poll.matches`, `poll.notifications`, and
`poll.errors` concurrently in a `withTaskGroup` (or pick the one you care
about). On a terminal failure, the error fires on `errors` and all three
streams close.

The longpoll path *also* requires a callback URL to be set on your account
(set it once via ``Streams/setCallbackURL(_:returnMetadata:)``); the SDK
preflights this on every `longpoll(...)` call by default and surfaces a
helpful error if it isn't set. Pass `LongpollOptions(skipCallbackCheck: true)`
to bypass.

### Tokenless longpoll

If you've derived a category server-side and want the client to subscribe
without ever holding the api_token, use ``LongpollConsumer``:

```swift
let consumer = LongpollConsumer(category: "abc123def")
defer { consumer.close() }

let poll = consumer.iterate()
defer { Task { await poll.close() } }

for await match in poll.matches {
    print("\(match.song.artist) — \(match.song.title)")
}
```

This carries no api_token; the category alone authorizes the subscription.

## Topics

### Stream management

- ``AudD/Stream``

### Callback parsing

- ``CallbackEvent``
- ``StreamCallbackMatch``
- ``StreamCallbackSong``
- ``StreamCallbackNotification``

### Longpoll

- ``LongpollPoll``
- ``LongpollOptions``
- ``LongpollConsumer``
