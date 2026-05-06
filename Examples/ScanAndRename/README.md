# ScanAndRename

Walk a folder of audio files, recognize each via AudD, optionally write the
recognized title/artist/album back into the file as metadata tags, then
rename the file to `Artist - Title.ext`.

Defaults to dry-run — pass `--apply` to actually touch files.

## Usage

```bash
export AUDD_API_TOKEN=...

# dry-run; prints what it would do
swift run ScanAndRename /path/to/folder

# do it for real, with 8 parallel recognitions
swift run ScanAndRename /path/to/folder --apply --concurrency 8
```

`-h` / `--help` prints the usage banner.

## Recognized extensions

`.mp3 .flac .ogg .opus .m4a .mp4 .wav .aac` — recursively. Hidden files are
skipped.

## Filename sanitization

Each component (artist, title) has the path-unsafe set
`/ \ : * ? " < > |` replaced with `_`, gets trimmed of leading/trailing
whitespace and dots, and is capped at 200 characters. The final filename is
`Artist - Title.<original-extension>`.

If a target with that name already exists, the rename is **skipped** and the
file is reported as a collision — the example will not silently overwrite.

## Tag writes — Apple-only

Linux-Swift has no first-class tag library; for cross-platform safety this
example only writes tags on Apple platforms (macOS / iOS / tvOS) and only
for `.m4a` and `.mp4` containers, via `AVAssetExportSession`.

| Platform / container | Behavior                                         |
|----------------------|--------------------------------------------------|
| macOS / iOS — `m4a`, `mp4` | Tags written, then file renamed             |
| macOS / iOS — other       | Tags skipped (format), file renamed         |
| Linux — any              | Tags skipped (platform), file renamed        |

`mp3` / `flac` / `ogg` / `opus` / `wav` / `aac` are recognized and renamed
on every platform but never get tag-write — bring your own tag library
(`taglib`, `id3lib`, `mutagen` via shell-out, etc.) if you need that.

The summary at the end of the run reports tags-written, tags-skipped (by
reason), and tags-failed counts, so you can see exactly what happened.

## Concurrency

`--concurrency N` (default `4`) bounds the number of in-flight recognitions
via an actor-backed semaphore. Tasks are dispatched into a `withTaskGroup`,
and results are reported in completion order.
