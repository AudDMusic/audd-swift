# AudD

Official Swift SDK for the [AudD](https://audd.io) music recognition API.
Swift 5.10+ / Swift 6 strict-concurrency clean, async/await, `Sendable` throughout, DocC-documented.

## Quickstart

`Package.swift`:

```swift
.package(url: "https://github.com/AudDMusic/audd-swift", from: "1.4.0"),
```

Then:

```swift
import AudD

let audd = try AudD(apiToken: "test")  // your token from https://dashboard.audd.io
if let result = try await audd.recognize("https://audd.tech/example.mp3") {
    print("\(result.artist ?? "") — \(result.title ?? "")")
}
```

## Capabilities

- `audd.recognize(...)` — public-database recognition.
- `audd.recognizeEnterprise(...)` — long-form (up to ~120 min) audio with chunked timecodes.
- `audd.streams.*` — radio-station stream setup, callback, and longpoll delivery.
- `audd.customCatalog.*` — custom-fingerprint upload + recognition.
- `audd.advanced.*` — typed wrappers for advanced endpoints.

## Examples

Runnable examples in `Examples/`. Each is its own SwiftPM target; run with
`swift run <name>`:

- `RecognizeUrl` — recognize a song from a public audio URL.
- `RecognizeFile` — recognize a song from a local file path.
- `RecognizeEnterprise` — long-form recognition on the enterprise endpoint.
- `StreamsSetup` — configure callback URL, subscribe a stream, list streams.
- `StreamsLongpoll` — receive stream events via longpoll.
- `CustomCatalogAdd` — add a song to your private fingerprint catalog.
- `TokenlessLongpoll` — tokenless longpoll consumer for browser/widget use cases.

## Concurrency

- `AudD` is an `actor`. All mutable state is actor-isolated; you can safely call any method from any `Task`. Token rotation via `setApiToken(...)` takes effect on the next inbound call; in-flight tasks continue with the prior token.
- All public model types conform to `Sendable`.
- Strict-concurrency clean: build with `-strict-concurrency=complete` produces zero warnings.
- The optional `onEvent` hook closure is `@Sendable` — it's called from the actor's executor; route to a logger of your choice (OSLog, Logger, your own actor).

## Errors

`AudDError` is the unified error type — see `Articles/Errors` in the DocC catalog for the full hierarchy. All errors carry an `httpStatus`, optional `errorCode`, optional `requestID`, and the raw response body for diagnostic plumbing.

## Documentation

The DocC catalog ships with the SDK:

```bash
swift package generate-documentation --target AudD
```

Or browse the catalog at [docs.audd.io/sdks/swift](https://docs.audd.io/sdks/swift) (when published).

## License

MIT — see [LICENSE](LICENSE).

## Support

- API reference: [docs.audd.io](https://docs.audd.io)
- Issues: [github.com/AudDMusic/audd-swift/issues](https://github.com/AudDMusic/audd-swift/issues)
- Email: [api@audd.io](mailto:api@audd.io)
