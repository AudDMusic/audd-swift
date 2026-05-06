# Streaming helpers

`streamingUrl(_:)`, `streamingUrls()`, and `previewUrl()` semantics.

## Overview

A successful match comes with a `songLink` and (when the caller passed
`return: ["apple_music", ...]`) one or more typed metadata blocks. The SDK
exposes three helpers that pick the right URL out of these without you having
to re-implement provider-specific routing:

- ``RecognitionResult/streamingUrl(_:)`` — best URL for one provider.
- ``RecognitionResult/streamingUrls()`` — every provider with a resolvable URL.
- ``RecognitionResult/previewUrl()`` — first 30-second preview URL across
  providers.
- ``RecognitionResult/thumbnailURL`` — cover-art URL for `lis.tn`-hosted song
  links.

Each helper has the same name and shape on ``EnterpriseMatch``; enterprise
responses don't carry per-provider metadata blocks, so those helpers are
lis.tn-redirect-only.

### Resolution order for `streamingUrl(_:)`

For each provider, the SDK picks the *best* URL in this order:

1. **Direct URL** from the metadata block (when the caller asked for it via
   `return: ["apple_music", ...]`). Direct = no redirect, fastest for clients.
   - `.appleMusic` → `apple_music.url`
   - `.spotify` → `spotify.external_urls.spotify`, then `spotify.uri`
   - `.deezer` → `deezer.link`
   - `.napster` → `napster.href` (in `extras`)
2. **lis.tn redirect** — `<songLink>?<provider>` when `songLink`'s host is
   `lis.tn`. Works for all providers including YouTube.
3. `nil` otherwise. YouTube has only the lis.tn-redirect path.

### Example

```swift
let result = try await audd.recognize(
    .url(URL(string: "https://audd.tech/example.mp3")!),
    return: ["apple_music", "spotify"]
)

// One provider:
if let appleURL = result?.streamingUrl(.appleMusic) {
    print(appleURL)  // direct apple_music.url
}

// Every resolvable provider:
for (provider, url) in (result?.streamingUrls() ?? [:]) {
    print("\(provider.rawValue): \(url)")
}

// 30-second preview, if any:
if let preview = result?.previewUrl() {
    print("Preview: \(preview)")
}
```

### Preview-URL TOS

`previewUrl()` returns a 30-second clip URL from
`apple_music.previews[0].url` → `spotify.preview_url` → `deezer.preview` (in
that priority order). Previews are governed by the respective providers' TOS;
**you** are responsible for honoring caching, attribution, and redistribution
constraints when serving them.

## Topics

### Streaming providers

- ``StreamingProvider``

### Methods

- ``RecognitionResult/streamingUrl(_:)``
- ``RecognitionResult/streamingUrls()``
- ``RecognitionResult/previewUrl()``
- ``RecognitionResult/thumbnailURL``
- ``EnterpriseMatch/streamingUrl(_:)``
- ``EnterpriseMatch/streamingUrls()``
- ``EnterpriseMatch/thumbnailURL``
