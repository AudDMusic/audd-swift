// Listen for AudD stream recognition events via longpoll, append every match
// as a CSV row.
//
// Two modes:
//
//   Provision-and-listen:
//     swift run StreamToCsv --url <stream-url> [--radio-id N] [--output FILE]
//
//     Adds the stream (auto-picks radio-id 99999 when --radio-id is absent),
//     polls the longpoll endpoint, and DELETES the stream on exit.
//
//   Listen-only:
//     swift run StreamToCsv --radio-id N [--output FILE]
//
//     Uses an existing stream slot. Does NOT add or delete. Refuses with a
//     pointer to setCallbackURL(...) if the account has no callback URL set.
//
// Default output: audd_stream_tracks.csv (append mode; header written only
// when the file is freshly created).
//
// Reads AUDD_API_TOKEN from the environment.
@preconcurrency import Foundation
import AudD

#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

// MARK: - CLI

struct StreamToCsvOptions {
    var url: String?
    var radioID: Int?
    var output: String
}

let defaultOutput = "audd_stream_tracks.csv"
let defaultProvisionRadioID = 99999

enum StreamToCsvCLI {
    static let usage = """
    swift run StreamToCsv --url <stream-url> [--radio-id N] [--output FILE]
    swift run StreamToCsv --radio-id N [--output FILE]

      --url URL          Provision-and-listen: adds this stream, polls,
                         deletes the stream on exit.
      --radio-id N       Stream slot identifier.
                           - With --url: explicit ID for the new stream.
                           - Without --url: listen-only on this existing slot;
                             does NOT add or delete.
                           - Defaults to 99999 in provision mode.
      --output FILE      CSV path (default audd_stream_tracks.csv). Appends.

    Reads AUDD_API_TOKEN from the environment.
    """

    static func parse(_ args: [String]) -> StreamToCsvOptions? {
        var url: String?
        var radioID: Int?
        var output = defaultOutput
        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "-h", "--help":
                return nil
            case "--url":
                i += 1
                if i >= args.count {
                    FileHandle.standardError.write(Data("--url requires a value\n".utf8))
                    return nil
                }
                url = args[i]
            case "--radio-id":
                i += 1
                if i >= args.count {
                    FileHandle.standardError.write(Data("--radio-id requires a number\n".utf8))
                    return nil
                }
                guard let n = Int(args[i]) else {
                    FileHandle.standardError.write(Data("--radio-id must be an integer\n".utf8))
                    return nil
                }
                radioID = n
            case "--output":
                i += 1
                if i >= args.count {
                    FileHandle.standardError.write(Data("--output requires a path\n".utf8))
                    return nil
                }
                output = args[i]
            default:
                FileHandle.standardError.write(Data("unknown argument: \(a)\n".utf8))
                return nil
            }
            i += 1
        }
        if url == nil && radioID == nil {
            FileHandle.standardError.write(Data("Must pass --url, --radio-id, or both.\n".utf8))
            return nil
        }
        return StreamToCsvOptions(url: url, radioID: radioID, output: output)
    }
}

// MARK: - CSV writing

let csvHeader = "received_at,radio_id,timestamp,score,artist,title,album,song_link\n"

func csvEscape(_ field: String) -> String {
    if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
    return field
}

func csvRow(_ fields: [String]) -> String {
    return fields.map(csvEscape).joined(separator: ",") + "\n"
}

/// Open the CSV output file in append mode. Writes header iff the file did
/// not exist (or was empty) before this call.
func openCsvHandle(path: String) throws -> FileHandle {
    let fm = FileManager.default
    let needHeader: Bool
    if fm.fileExists(atPath: path) {
        let attrs = try? fm.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? 0
        needHeader = size == 0
    } else {
        fm.createFile(atPath: path, contents: nil, attributes: nil)
        needHeader = true
    }
    let handle = FileHandle(forWritingAtPath: path)
    guard let handle else {
        throw NSError(domain: "StreamToCsv", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "could not open \(path) for writing"
        ])
    }
    try handle.seekToEnd()
    if needHeader {
        try handle.write(contentsOf: Data(csvHeader.utf8))
    }
    return handle
}

// MARK: - Payload extraction

struct ExtractedMatch {
    var radioID: Int
    var timestamp: String
    var score: Int
    var artist: String
    var title: String
    var album: String
    var songLink: String
}

/// Pull every recognition entry out of one longpoll envelope.
///
/// AudD longpoll envelopes wrap either a recognition (`result: {...}`) or a
/// notification (`notification: {...}`). The recognition variant looks like:
///   {
///     "time": <int>,
///     "timestamp": <int>,
///     "result": {
///       "radio_id": N,
///       "timestamp": "...",
///       "play_length": ...,
///       "results": [ { artist, title, album, song_link, score, ... }, ... ]
///     }
///   }
///
/// We iterate every entry inside `result.results`. Notifications return [].
func extractMatches(from payload: [String: AnyCodable]) -> [ExtractedMatch] {
    var any: [String: Any] = [:]
    for (k, v) in payload { any[k] = v.value }
    guard let resultDict = any["result"] as? [String: Any] else {
        return []
    }
    let radioID = (resultDict["radio_id"] as? Int)
        ?? Int((resultDict["radio_id"] as? String) ?? "")
        ?? 0
    let resultTimestamp = (resultDict["timestamp"] as? String) ?? ""
    guard let entries = resultDict["results"] as? [[String: Any]] else {
        return []
    }
    var out: [ExtractedMatch] = []
    for entry in entries {
        let score = (entry["score"] as? Int) ?? Int((entry["score"] as? String) ?? "") ?? 0
        let artist = (entry["artist"] as? String) ?? ""
        let title = (entry["title"] as? String) ?? ""
        let album = (entry["album"] as? String) ?? ""
        let songLink = (entry["song_link"] as? String) ?? ""
        out.append(ExtractedMatch(
            radioID: radioID,
            timestamp: resultTimestamp,
            score: score,
            artist: artist,
            title: title,
            album: album,
            songLink: songLink
        ))
    }
    return out
}

func formatNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}

// MARK: - SIGINT

/// Latch a flag when SIGINT arrives. Used to signal the longpoll loop and the
/// stream-deletion path on the way out.
final class SigintFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func mark() {
        lock.lock(); defer { lock.unlock() }
        fired = true
    }

    var isFired: Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }
}

let sigintFlag = SigintFlag()

func installSigintHandler() {
    signal(SIGINT) { _ in
        sigintFlag.mark()
    }
}

// MARK: - Provisioning helpers

let placeholderCallbackURL = "https://audd.tech/empty/"

enum CallbackProvision {
    case alreadySet
    case justSetPlaceholder
}

/// Mode 1 (provision): ensure a callback URL exists. If the account has none
/// (server returns code 19), set `https://audd.tech/empty/` ourselves.
/// Returns whether we touched it (used to compose the exit message).
func ensureCallbackForProvisionMode(streams: Streams) async throws -> CallbackProvision {
    do {
        _ = try await streams.getCallbackURL()
        return .alreadySet
    } catch let AudDError.api(detail) where detail.errorCode == 19 {
        // Code 19 = "no callback URL configured". Set a placeholder ourselves.
        try await streams.setCallbackURL(placeholderCallbackURL)
        return .justSetPlaceholder
    }
}

/// Mode 2 (listen-only): refuse if the account has no callback URL.
func assertCallbackForListenMode(streams: Streams) async throws {
    do {
        _ = try await streams.getCallbackURL()
    } catch let AudDError.api(detail) where detail.errorCode == 19 {
        throw AudDError.api(AudDAPIErrorDetail(
            kind: .invalidRequest,
            errorCode: 19,
            message: """
                stream slot exists but no callback URL is configured for this \
                account; longpoll won't deliver events. Set one first via \
                streams.setCallbackURL(\"https://audd.tech/empty/\") (or your \
                real receiver URL) and re-run.
                """,
            httpStatus: detail.httpStatus,
            requestID: detail.requestID
        ))
    }
}

// MARK: - Entry point

@main
struct StreamToCsvApp {
    static func main() async {
        guard let opts = StreamToCsvCLI.parse(CommandLine.arguments) else {
            print(StreamToCsvCLI.usage)
            exit(1)
        }

        installSigintHandler()

        let provisionMode = (opts.url != nil)
        let radioID = opts.radioID ?? defaultProvisionRadioID

        let audd: AudD
        do {
            audd = try AudD()  // reads AUDD_API_TOKEN from env
        } catch {
            FileHandle.standardError.write(Data("Failed to construct AudD client: \(error)\n".utf8))
            exit(1)
        }
        defer {
            Task { await audd.close() }
        }

        let streams = await audd.streams

        // Stage 1: callback-URL handling per mode.
        var provisioned: CallbackProvision = .alreadySet
        do {
            if provisionMode {
                provisioned = try await ensureCallbackForProvisionMode(streams: streams)
                switch provisioned {
                case .alreadySet:
                    break
                case .justSetPlaceholder:
                    FileHandle.standardError.write(Data(
                        "longpoll requires any 200-OK URL server-side; using audd.tech/empty/ as a default.\n".utf8
                    ))
                }
            } else {
                try await assertCallbackForListenMode(streams: streams)
            }
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }

        // Stage 2: provision the stream (mode 1 only).
        if provisionMode, let url = opts.url {
            do {
                try await streams.add(url: url, radioID: radioID)
                FileHandle.standardError.write(Data(
                    "Added stream: radio_id=\(radioID) url=\(url)\n".utf8
                ))
            } catch {
                FileHandle.standardError.write(Data(
                    "Failed to add stream: \(error.localizedDescription)\n".utf8
                ))
                exit(1)
            }
        }

        // Stage 3: open the CSV output.
        let csv: FileHandle
        do {
            csv = try openCsvHandle(path: opts.output)
        } catch {
            FileHandle.standardError.write(Data(
                "Failed to open \(opts.output): \(error.localizedDescription)\n".utf8
            ))
            await teardown(streams: streams, provisionMode: provisionMode, radioID: radioID,
                           provisioned: provisioned)
            exit(1)
        }
        FileHandle.standardError.write(Data("Writing matches to \(opts.output)\n".utf8))

        // Stage 4: longpoll and append rows. Loop exits when SIGINT arrives or
        // the longpoll task throws.
        let category = streams.deriveLongpollCategory(radioID: radioID)
        FileHandle.standardError.write(Data(
            "Longpolling category=\(category) radio_id=\(radioID). Press Ctrl-C to exit.\n".utf8
        ))

        let pollTask: Task<Void, Error> = Task {
            for try await payload in streams.longpoll(category: category, timeout: 30) {
                if sigintFlag.isFired { break }
                if let notification = payload["notification"]?.value {
                    FileHandle.standardError.write(Data(
                        "[notification] \(notification)\n".utf8
                    ))
                    continue
                }
                let matches = extractMatches(from: payload)
                let now = formatNow()
                for m in matches {
                    let row = csvRow([
                        now,
                        String(m.radioID),
                        m.timestamp,
                        String(m.score),
                        m.artist,
                        m.title,
                        m.album,
                        m.songLink,
                    ])
                    do {
                        try csv.write(contentsOf: Data(row.utf8))
                    } catch {
                        FileHandle.standardError.write(Data(
                            "CSV write failed: \(error.localizedDescription)\n".utf8
                        ))
                    }
                    FileHandle.standardError.write(Data(
                        "[match] \(m.artist) — \(m.title) (score=\(m.score))\n".utf8
                    ))
                }
            }
        }

        // Watcher task: when SIGINT fires, cancel the polling task.
        let watcher = Task {
            while !Task.isCancelled {
                if sigintFlag.isFired {
                    pollTask.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        // Wait for either the polling to end naturally or SIGINT to cancel it.
        do {
            try await pollTask.value
        } catch is CancellationError {
            // Expected on SIGINT.
        } catch {
            FileHandle.standardError.write(Data(
                "Longpoll terminated: \(error.localizedDescription)\n".utf8
            ))
        }
        watcher.cancel()

        try? csv.close()
        await teardown(
            streams: streams,
            provisionMode: provisionMode,
            radioID: radioID,
            provisioned: provisioned
        )
    }

    static func teardown(
        streams: Streams,
        provisionMode: Bool,
        radioID: Int,
        provisioned: CallbackProvision
    ) async {
        if provisionMode {
            do {
                try await streams.delete(radioID: radioID)
                FileHandle.standardError.write(Data(
                    "Deleted stream radio_id=\(radioID).\n".utf8
                ))
            } catch {
                let msg = "Warning: stream delete failed: \(error.localizedDescription). " +
                    "Run streams.delete(radioID: \(radioID)) manually if needed.\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
            if case .justSetPlaceholder = provisioned {
                FileHandle.standardError.write(Data(
                    "left audd.tech/empty/ as your account callback — change it via setCallbackURL(...) if needed.\n".utf8
                ))
            }
        }
    }
}
