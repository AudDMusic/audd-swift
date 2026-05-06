// Walk a folder of audio files, recognize each via AudD, optionally write
// metadata tags into the file (Apple platforms only), and rename to
// "Artist - Title.ext".
//
// Usage:
//   swift run ScanAndRename <folder>                    # dry-run (default)
//   swift run ScanAndRename <folder> --apply            # actually rename
//   swift run ScanAndRename <folder> --apply --concurrency 8
//
// Recognition uses the `AudD(apiToken:)` constructor which reads
// `AUDD_API_TOKEN` from the environment when no token is passed.
//
// Tag writes:
//   - On Apple platforms (macOS / iOS / tvOS): writes into .m4a / .mp4
//     containers via AVAssetExportSession.
//   - On Linux: tag-write is skipped (no portable Linux Swift tag library);
//     the file is still renamed. See README.md for details.
//
// Renames are skipped on collision (target exists). Sanitization replaces
// the path-unsafe set [/ \ : * ? " < > |] with `_` and caps each component
// at 200 chars.
#if os(macOS) || os(Linux)
@preconcurrency import Foundation
import AudD

#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - CLI

struct ScanAndRenameOptions {
    var folder: URL
    var apply: Bool
    var concurrency: Int
}

enum ScanAndRenameCLI {
    static let usage = """
    swift run ScanAndRename <folder> [--apply] [--concurrency N]

      <folder>           Path to a directory; walked recursively.
      --apply            Actually rename files. Without this flag, runs in
                         dry-run mode and only prints what would happen.
      --concurrency N    Parallel recognitions (default 4).

    Reads AUDD_API_TOKEN from the environment.

    Recognized audio extensions:
      .mp3 .flac .ogg .opus .m4a .mp4 .wav .aac

    Tag writes happen only on Apple platforms (m4a/mp4). On Linux the file
    is renamed; tag-write is skipped with a per-file note.
    """

    static func parse(_ args: [String]) -> ScanAndRenameOptions? {
        var folder: String?
        var apply = false
        var concurrency = 4
        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "-h", "--help":
                return nil
            case "--apply":
                apply = true
            case "--concurrency":
                i += 1
                if i >= args.count {
                    FileHandle.standardError.write(Data("--concurrency requires a number\n".utf8))
                    return nil
                }
                guard let n = Int(args[i]), n >= 1 else {
                    FileHandle.standardError.write(Data("--concurrency must be a positive integer\n".utf8))
                    return nil
                }
                concurrency = n
            default:
                if a.hasPrefix("-") {
                    FileHandle.standardError.write(Data("unknown flag: \(a)\n".utf8))
                    return nil
                }
                if folder != nil {
                    FileHandle.standardError.write(Data("only one folder argument allowed\n".utf8))
                    return nil
                }
                folder = a
            }
            i += 1
        }
        guard let folder else { return nil }
        return ScanAndRenameOptions(
            folder: URL(fileURLWithPath: folder),
            apply: apply,
            concurrency: concurrency
        )
    }
}

// MARK: - Sanitization

let unsafeFilenameCharacters: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]

func sanitizeFilenameComponent(_ s: String, maxLength: Int = 200) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        if unsafeFilenameCharacters.contains(ch) || ch.asciiValue == 0 {
            out.append("_")
        } else {
            out.append(ch)
        }
    }
    // Trim leading/trailing whitespace + dots; the latter trips Windows tooling.
    let trimmed = out.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    if trimmed.count <= maxLength { return trimmed }
    return String(trimmed.prefix(maxLength))
}

// MARK: - Walk

let audioExtensions: Set<String> = ["mp3", "flac", "ogg", "opus", "m4a", "mp4", "wav", "aac"]

func enumerateAudioFiles(in folder: URL) -> [URL] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
        return []
    }
    guard let enumerator = fm.enumerator(
        at: folder,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }
    var out: [URL] = []
    for case let fileURL as URL in enumerator {
        let ext = fileURL.pathExtension.lowercased()
        guard audioExtensions.contains(ext) else { continue }
        if let isReg = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
           isReg == true {
            out.append(fileURL)
        }
    }
    return out
}

// MARK: - Tag write

enum TagWriteOutcome {
    case wrote
    case skippedFormat       // unsupported container on this platform
    case skippedPlatform     // no tag library on Linux
    case failed(String)
}

#if canImport(AVFoundation)
/// Returns whether AVAssetExportSession can rewrite this container.
/// We restrict to .m4a / .mp4 — the formats AVFoundation reliably round-trips
/// on Apple platforms.
func avSupportedContainer(_ ext: String) -> Bool {
    return ext == "m4a" || ext == "mp4"
}

/// Rewrite the file with `title` / `artist` set as common-key metadata items.
/// Uses an AVAssetExportSession against an in-place temp file, then atomically
/// replaces the original.
@available(macOS 10.15, iOS 13, tvOS 13, *)
func writeTagsAVFoundation(
    fileURL: URL,
    artist: String,
    title: String,
    album: String?
) async -> TagWriteOutcome {
    let ext = fileURL.pathExtension.lowercased()
    guard avSupportedContainer(ext) else {
        return .skippedFormat
    }
    let asset = AVAsset(url: fileURL)
    let preset = AVAssetExportPresetPassthrough
    guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
        return .failed("AVAssetExportSession init returned nil")
    }
    let tmp = fileURL
        .deletingLastPathComponent()
        .appendingPathComponent(".audd-tagwrite-\(UUID().uuidString).\(ext)")
    session.outputURL = tmp
    session.outputFileType = ext == "mp4" ? .mp4 : .m4a
    var items: [AVMetadataItem] = []
    items.append(makeMetadataItem(.commonKeyTitle, value: title))
    items.append(makeMetadataItem(.commonKeyArtist, value: artist))
    if let album, !album.isEmpty {
        items.append(makeMetadataItem(.commonKeyAlbumName, value: album))
    }
    session.metadata = items
    await session.export()
    if session.status != .completed {
        let msg = session.error?.localizedDescription ?? "export status \(session.status.rawValue)"
        try? FileManager.default.removeItem(at: tmp)
        return .failed(msg)
    }
    do {
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        return .wrote
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        return .failed("replace failed: \(error.localizedDescription)")
    }
}

func makeMetadataItem(_ key: AVMetadataKey, value: String) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.keySpace = .common
    item.key = key as NSString
    item.value = value as NSString
    return item
}
#endif

func writeTagsBestEffort(
    fileURL: URL,
    artist: String,
    title: String,
    album: String?
) async -> TagWriteOutcome {
    #if canImport(AVFoundation)
    if #available(macOS 10.15, iOS 13, tvOS 13, *) {
        return await writeTagsAVFoundation(fileURL: fileURL, artist: artist, title: title, album: album)
    } else {
        return .skippedPlatform
    }
    #else
    return .skippedPlatform
    #endif
}

// MARK: - Per-file pipeline

struct PerFileResult: Sendable {
    enum Outcome: Sendable {
        case noMatch
        case error(String)
        case skippedCollision(target: String)
        case planned(target: String, tagOutcome: TagOutcomeSendable)
        case applied(target: String, tagOutcome: TagOutcomeSendable)
    }
    let source: URL
    let outcome: Outcome
}

enum TagOutcomeSendable: Sendable {
    case wrote
    case skippedFormat
    case skippedPlatform
    case failed(String)
    case notAttempted   // dry-run

    init(from outcome: TagWriteOutcome) {
        switch outcome {
        case .wrote: self = .wrote
        case .skippedFormat: self = .skippedFormat
        case .skippedPlatform: self = .skippedPlatform
        case .failed(let m): self = .failed(m)
        }
    }
}

func processFile(
    audd: AudD,
    fileURL: URL,
    apply: Bool
) async -> PerFileResult {
    do {
        let result = try await audd.recognize(.file(fileURL))
        guard let result, let artist = result.artist, !artist.isEmpty,
              let title = result.title, !title.isEmpty
        else {
            return PerFileResult(source: fileURL, outcome: .noMatch)
        }
        let cleanArtist = sanitizeFilenameComponent(artist)
        let cleanTitle = sanitizeFilenameComponent(title)
        let ext = fileURL.pathExtension
        let newName = "\(cleanArtist) - \(cleanTitle).\(ext)"
        let target = fileURL.deletingLastPathComponent().appendingPathComponent(newName)

        if target.path == fileURL.path {
            // Already named correctly — nothing to do.
            return PerFileResult(
                source: fileURL,
                outcome: apply
                    ? .applied(target: target.path, tagOutcome: .notAttempted)
                    : .planned(target: target.path, tagOutcome: .notAttempted)
            )
        }
        if FileManager.default.fileExists(atPath: target.path) {
            return PerFileResult(source: fileURL, outcome: .skippedCollision(target: target.path))
        }

        if !apply {
            return PerFileResult(
                source: fileURL,
                outcome: .planned(target: target.path, tagOutcome: .notAttempted)
            )
        }

        // Write tags first, then rename.
        let tagOutcome = await writeTagsBestEffort(
            fileURL: fileURL, artist: artist, title: title, album: result.album
        )
        let tagSendable = TagOutcomeSendable(from: tagOutcome)

        do {
            try FileManager.default.moveItem(at: fileURL, to: target)
        } catch {
            return PerFileResult(
                source: fileURL,
                outcome: .error("rename failed: \(error.localizedDescription)")
            )
        }
        return PerFileResult(source: fileURL, outcome: .applied(target: target.path, tagOutcome: tagSendable))
    } catch {
        return PerFileResult(source: fileURL, outcome: .error(String(describing: error)))
    }
}

// MARK: - Concurrency throttle

/// Simple actor-backed counting semaphore for a fixed permit pool.
actor ConcurrencyLimit {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ n: Int) { self.permits = max(1, n) }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            permits += 1
        }
    }
}

// MARK: - Reporting

func describe(_ outcome: TagOutcomeSendable) -> String {
    switch outcome {
    case .wrote: return "tags=wrote"
    case .skippedFormat: return "tags=skipped (format unsupported by AVFoundation)"
    case .skippedPlatform: return "tags=skipped (Linux: no portable Swift tag library)"
    case .failed(let m): return "tags=failed (\(m))"
    case .notAttempted: return "tags=skipped (dry-run)"
    }
}

func printResult(_ r: PerFileResult, apply: Bool) {
    let src = r.source.path
    switch r.outcome {
    case .noMatch:
        print("[no match]   \(src)")
    case .error(let m):
        print("[error]      \(src) — \(m)")
    case .skippedCollision(let target):
        print("[collision]  \(src) -> \(target) (target exists)")
    case .planned(let target, let tagOutcome):
        print("[plan]       \(src) -> \(target)  \(describe(tagOutcome))")
    case .applied(let target, let tagOutcome):
        print("[done]       \(src) -> \(target)  \(describe(tagOutcome))")
    }
}

struct Tally {
    var total = 0
    var renamed = 0
    var planned = 0
    var noMatch = 0
    var collisions = 0
    var errors = 0
    var tagWrote = 0
    var tagSkippedFormat = 0
    var tagSkippedPlatform = 0
    var tagFailed = 0
}

func tallyAdd(_ tally: inout Tally, _ r: PerFileResult) {
    tally.total += 1
    switch r.outcome {
    case .noMatch: tally.noMatch += 1
    case .error: tally.errors += 1
    case .skippedCollision: tally.collisions += 1
    case .planned: tally.planned += 1
    case .applied(_, let t):
        tally.renamed += 1
        switch t {
        case .wrote: tally.tagWrote += 1
        case .skippedFormat: tally.tagSkippedFormat += 1
        case .skippedPlatform: tally.tagSkippedPlatform += 1
        case .failed: tally.tagFailed += 1
        case .notAttempted: break
        }
    }
}

// MARK: - Entry point

@main
struct ScanAndRenameApp {
    static func main() async {
        guard let opts = ScanAndRenameCLI.parse(CommandLine.arguments) else {
            print(ScanAndRenameCLI.usage)
            exit(1)
        }

        let files = enumerateAudioFiles(in: opts.folder)
        if files.isEmpty {
            print("No audio files found under \(opts.folder.path)")
            exit(0)
        }
        print("Found \(files.count) audio file(s) under \(opts.folder.path).")
        print("Mode: \(opts.apply ? "APPLY (renaming)" : "dry-run").  Concurrency: \(opts.concurrency).")

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

        let limit = ConcurrencyLimit(opts.concurrency)
        var tally = Tally()

        await withTaskGroup(of: PerFileResult.self) { group in
            for file in files {
                await limit.acquire()
                group.addTask {
                    let r = await processFile(audd: audd, fileURL: file, apply: opts.apply)
                    await limit.release()
                    return r
                }
            }
            for await r in group {
                printResult(r, apply: opts.apply)
                tallyAdd(&tally, r)
            }
        }

        print("")
        print("Summary:")
        print("  total scanned:    \(tally.total)")
        if opts.apply {
            print("  renamed:          \(tally.renamed)")
        } else {
            print("  would rename:     \(tally.planned)")
        }
        print("  no match:         \(tally.noMatch)")
        print("  collisions:       \(tally.collisions)")
        print("  errors:           \(tally.errors)")
        if opts.apply {
            print("  tags written:     \(tally.tagWrote)")
            print("  tags skipped (format):    \(tally.tagSkippedFormat)")
            print("  tags skipped (platform):  \(tally.tagSkippedPlatform)")
            print("  tags failed:      \(tally.tagFailed)")
        }
    }
}
#else
// CLI examples run on macOS and Linux. iOS/tvOS/watchOS/visionOS get a stub
// so the package still builds cleanly on every declared platform.
@main
struct ScanAndRename_UnsupportedPlatformStub {
    static func main() {
        print("This CLI example is intended for macOS or Linux.")
    }
}
#endif
