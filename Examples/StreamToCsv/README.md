# StreamToCsv

Listen for AudD stream-recognition events via longpoll and append every
match to a CSV file.

## Two modes

### Provision-and-listen

```bash
export AUDD_API_TOKEN=...
swift run StreamToCsv --url https://npr-ice.streamguys1.com/live.mp3
```

Adds the stream (auto-picks `radio_id 99999` when `--radio-id` is absent),
polls, and **deletes** the stream when the process exits (SIGINT or natural
shutdown). Pass `--radio-id N` together with `--url` to use an explicit ID.

### Listen-only

```bash
swift run StreamToCsv --radio-id 1
```

Uses an existing stream slot. **Does not** add or delete. If the account has
no callback URL configured, refuses with a pointer to `setCallbackURL(...)`.

## Output

```bash
swift run StreamToCsv --url ... --output tracks.csv
```

Default path is `audd_stream_tracks.csv` in the current directory. Append
mode — re-runs add rows to the same file. The header row is written **only**
when the file is freshly created (or empty).

Columns:

```
received_at,radio_id,timestamp,score,artist,title,album,song_link
```

`received_at` is local wall-clock at the moment the longpoll event was
received (ISO-8601 with fractional seconds). `timestamp` is the AudD-supplied
play timestamp from the result envelope.

## Callback URL handling

AudD's longpoll endpoint requires a callback URL on the account, even though
longpoll itself doesn't deliver to it. The two modes handle this differently:

- **Provision mode** — if the account has no callback URL (server returns
  error `#19`), the example sets `https://audd.tech/empty/` itself and warns
  on stderr that this happened. On exit, prints a reminder that the
  placeholder URL is still set and how to change it.
- **Listen-only mode** — if the account has no callback URL, the example
  refuses up front with a pointer to `streams.setCallbackURL(...)`. It
  doesn't touch your account configuration.

If a real URL is already configured, neither mode touches it.

## Shutdown

`Ctrl-C` (SIGINT) closes the longpoll cleanly, flushes the CSV, and (in
provision mode) deletes the stream slot.
