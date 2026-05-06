# Errors

The error hierarchy and how to handle each variant.

## Overview

The SDK uses a single ``AudDError`` enum. Discriminate on its cases — and on
``AudDAPIErrorDetail/kind`` for `.api(...)` errors — to choose the right
recovery path.

### Cases

- ``AudDError/api(_:)`` — the server responded with `status: error`. Inspect
  ``AudDAPIErrorDetail/kind`` (an ``AudDErrorKind``) to classify.
- ``AudDError/serverError(httpStatus:message:requestID:rawText:)`` — non-2xx
  HTTP with a non-JSON body. Gateway HTML, etc.
- ``AudDError/connection(message:underlying:)`` — network / DNS / TLS / read
  timeout. No HTTP response was received.
- ``AudDError/serializationError(message:rawText:)`` — 2xx but the body wasn't
  shaped as expected.
- ``AudDError/invalidArgument(_:)`` — caller-side validation problem before
  anything was sent (e.g. an unparseable URL).
- ``AudDError/unsupportedSource(_:)`` — retrying an unseekable
  ``Source/stream(_:name:)`` after the buffer was already drained.
- ``AudDError/configuration(_:)`` — missing api_token (no explicit value and
  `AUDD_API_TOKEN` env var unset), invalid token rotation, etc.

### Catch by case

```swift
do {
    let result = try await audd.recognize(source)
    // ...
} catch let AudDError.api(detail) where detail.kind == .authentication {
    // 900, 901, 903 — bad / missing api_token
    print("auth failed: \(detail.message)")
} catch let AudDError.api(detail) where detail.kind == .quota {
    // 902 — daily quota exceeded
    print("quota: \(detail.message)")
} catch let AudDError.api(detail) where detail.kind == .invalidAudio {
    // 300, 400, 500 — file is empty, too short, or unreadable
    print("invalid audio: \(detail.message)")
} catch AudDError.connection(let message, _) {
    // network failure (also raised when the SDK exhausts retries)
    print("connection: \(message)")
} catch AudDError.configuration(let message) {
    // setup problem before any request was sent
    print("config: \(message)")
} catch {
    print("other: \(error)")
}
```

### Error-kind catalog

The full ``AudDErrorKind`` covers 25+ AudD numeric error codes. Highlights:

- `.authentication` — codes 900, 901, 903.
- `.quota` — code 902.
- `.subscription` — codes 904, 905.
- `.customCatalogAccess` — code 904 raised specifically from
  ``CustomCatalog/add(audioID:source:)``. The user-facing message includes a
  custom-catalog-vs.-recognition hint.
- `.invalidRequest` — codes 50, 51, 600, 601, 602, 700, 701, 702, 906.
- `.invalidAudio` — codes 300, 400, 500.
- `.rateLimit` — code 611, HTTP 429.
- `.streamLimit` — code 610.
- `.notReleased` — code 907 (track not released yet).
- `.blocked` — codes 19, 31337.
- `.needsUpdate` — code 20.
- `.server` — codes 100, 1000; generic upstream / non-2xx.

### Inspecting `requestID`

Every API and serverError variant carries the `X-Request-Id` from the server
when one was returned (see ``AudDAPIErrorDetail/requestID``). Include it when
filing a support ticket.

## Topics

### Error types

- ``AudDError``
- ``AudDErrorKind``
- ``AudDAPIErrorDetail``
