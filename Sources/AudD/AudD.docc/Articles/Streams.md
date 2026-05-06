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

When a song is matched, AudD POSTs to your callback URL. Parse the body with
``Streams/parseCallback(_:)``:

```swift
// Inside your HTTP handler, given the parsed JSON dict `body`:
let payload = try await audd.streams.parseCallback(body)
if let result = payload.result {
    for entry in result.results {
        print("\(entry.artist) — \(entry.title)")
    }
} else if let notification = payload.notification {
    print("Stream event: \(notification.notificationMessage)")
}
```

### Longpoll (no receiver needed)

Subscribe to events by polling — useful for clients that can't expose an HTTP
endpoint.

```swift
let category = audd.streams.deriveLongpollCategory(radioID: 42)

let stream = await audd.streams.longpoll(category: category)
for try await event in stream {
    print(event)
}
```

The longpoll path *also* requires a callback URL to be set on your account
(set it once via ``Streams/setCallbackURL(_:returnMetadata:)``); the SDK
preflights this on every `longpoll(...)` call by default and surfaces a
helpful error if it isn't set. Pass `skipCallbackCheck: true` to bypass.

### Tokenless longpoll

If you've derived a category server-side and want the client to subscribe
without ever holding the api_token, use ``LongpollConsumer``:

```swift
let consumer = LongpollConsumer(category: "abc123def")
defer { consumer.close() }

for try await event in consumer.iterate() {
    print(event)
}
```

This carries no api_token; the category alone authorizes the subscription.

## Topics

### Stream management

- ``AudD/Stream``

### Callback parsing

- ``StreamCallbackPayload``
- ``StreamCallbackResult``
- ``StreamCallbackResultEntry``
- ``StreamCallbackNotification``

### Longpoll

- ``LongpollConsumer``
