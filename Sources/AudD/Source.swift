// Source enum + the C1 per-attempt re-opener pattern.
//
// URLSession does NOT auto-rewind file handles between requests, so the
// re-opener returns a fresh request body on every retry attempt. See spec §7.1.
//
// Public API: `Source` is what callers pass; internally we transform it into a
// closure of type `() throws -> RequestBody` that's invoked once per attempt.
//
// `@preconcurrency import Foundation` — Foundation's `URL` isn't formally
// `Sendable` on Linux/Swift 5.10, but it's a value type and safe to share.
@preconcurrency import Foundation

/// Audio source for `recognize(...)` / `recognizeEnterprise(...)` / `customCatalog.add(...)`.
public enum Source: @unchecked Sendable {
    /// An audio URL the AudD server will fetch. Goes in the `url` form field.
    /// Use `.url(URL(string: "https://...")!)`.
    case url(URL)

    /// A local file path. The SDK opens a fresh handle on each retry attempt.
    case file(URL)

    /// Raw bytes. The buffer is reused across retries.
    case data(Data)

    /// An `InputStream`. The SDK reads it ONCE into memory; retries use the
    /// buffered bytes. (Streaming-without-buffering would prevent retry, which
    /// the spec disallows. This matches audd-python's behavior for non-tell()-able streams.)
    case stream(InputStream, name: String? = nil)
}

/// Internal request body shape. Either the source goes in `url=` (no multipart)
/// or in a `file=` part (multipart).
struct PreparedRequest: Sendable {
    /// Form fields (e.g. `url`, `audio_id`, `return`). The `api_token` is added
    /// by the HTTP layer — never set it here.
    var formFields: [String: String]
    /// File part: (name, mime, bytes). Nil when the source is a URL.
    var filePart: FilePart?
}

struct FilePart: Sendable {
    var name: String
    var mime: String
    var data: Data
}

/// Returns a re-opener closure. Calling it produces a fresh `PreparedRequest`
/// per retry attempt.
///
/// - For `.url`: each call returns a tiny `PreparedRequest` with `url=...` only.
/// - For `.file`: each call reads the file fresh.
/// - For `.data`: each call references the same buffer.
/// - For `.stream`: the stream is drained once into memory on first call,
///   then reused. (Cannot rewind an `InputStream` portably.)
///
/// The returned closure is `@Sendable` so retry/scheduling layers can pass it
/// across actor boundaries. The `.stream` variant is gated by an internal
/// reference-typed buffer; access is single-threaded by construction (one
/// re-opener invocation per attempt, run sequentially by the retry loop).
func prepareSource(_ source: Source) throws -> @Sendable () throws -> PreparedRequest {
    switch source {
    case .url(let url):
        let str = url.absoluteString
        return {
            PreparedRequest(
                formFields: ["url": str],
                filePart: nil
            )
        }

    case .file(let fileURL):
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            throw AudDError.invalidArgument(
                "File does not exist at path \(fileURL.path); pass a URL, a file URL, or Data."
            )
        }
        let name = fileURL.lastPathComponent
        return {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw AudDError.connection(
                    message: "Could not read file at \(fileURL.path): \(error.localizedDescription)",
                    underlying: error
                )
            }
            return PreparedRequest(
                formFields: [:],
                filePart: FilePart(
                    name: name.isEmpty ? "upload.bin" : name,
                    mime: "application/octet-stream",
                    data: data
                )
            )
        }

    case .data(let data):
        return {
            PreparedRequest(
                formFields: [:],
                filePart: FilePart(
                    name: "upload.bin",
                    mime: "application/octet-stream",
                    data: data
                )
            )
        }

    case .stream(let inputStream, let name):
        // Drain once. Subsequent calls reuse the same buffer.
        // We use a class wrapper so the closure can mutate the cache.
        let cache = StreamBuffer(stream: inputStream, name: name ?? "upload.bin")
        return {
            try cache.dataForAttempt()
        }
    }
}

/// `@unchecked Sendable`: the buffer is invoked once per retry attempt by the
/// retry loop, which executes sequentially (await between attempts). No
/// concurrent access in practice.
private final class StreamBuffer: @unchecked Sendable {
    let stream: InputStream
    let name: String
    private var cached: Data?
    private var drained: Bool = false

    init(stream: InputStream, name: String) {
        self.stream = stream
        self.name = name
    }

    func dataForAttempt() throws -> PreparedRequest {
        if let cached {
            return PreparedRequest(
                formFields: [:],
                filePart: FilePart(name: name, mime: "application/octet-stream", data: cached)
            )
        }
        if drained {
            throw AudDError.unsupportedSource(
                "Cannot retry an unseekable InputStream source. Pass Data (buffer the bytes yourself) or use a file URL or URL."
            )
        }
        drained = true
        if stream.streamStatus == .notOpen {
            stream.open()
        }
        defer {
            stream.close()
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var collected = Data()
        while stream.hasBytesAvailable {
            let read = buffer.withUnsafeMutableBufferPointer { buf -> Int in
                guard let base = buf.baseAddress else { return 0 }
                return stream.read(base, maxLength: buf.count)
            }
            if read < 0 {
                if let error = stream.streamError {
                    throw AudDError.connection(message: "InputStream error: \(error.localizedDescription)", underlying: error)
                }
                throw AudDError.connection(message: "InputStream read failed", underlying: nil)
            }
            if read == 0 {
                break
            }
            collected.append(buffer, count: read)
        }
        cached = collected
        return PreparedRequest(
            formFields: [:],
            filePart: FilePart(name: name, mime: "application/octet-stream", data: collected)
        )
    }
}
