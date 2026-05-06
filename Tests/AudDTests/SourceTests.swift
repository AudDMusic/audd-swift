// Source / re-opener tests. Confirms the C1 pattern: each closure call returns
// a fresh (copy of) request body so retries don't read from an exhausted source.
import XCTest
@testable import AudD

final class SourceTests: XCTestCase {
    func testURLSource() throws {
        let url = URL(string: "https://example.com/file.mp3")!
        let reopen = try prepareSource(.url(url))
        let prepared = try reopen()
        XCTAssertEqual(prepared.formFields["url"], url.absoluteString)
        XCTAssertNil(prepared.filePart)
        // Second call returns same content
        let prepared2 = try reopen()
        XCTAssertEqual(prepared2.formFields["url"], url.absoluteString)
    }

    func testDataSourceReopens() throws {
        let payload = "audio bytes".data(using: .utf8)!
        let reopen = try prepareSource(.data(payload))
        for _ in 0..<3 {
            let prepared = try reopen()
            XCTAssertEqual(prepared.filePart?.data, payload)
            XCTAssertEqual(prepared.filePart?.name, "upload.bin")
        }
    }

    func testFileSourceReopens() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("audd-test-\(UUID().uuidString).bin")
        let payload = Data([0xde, 0xad, 0xbe, 0xef])
        try payload.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let reopen = try prepareSource(.file(temp))
        for _ in 0..<3 {
            let prepared = try reopen()
            XCTAssertEqual(prepared.filePart?.data, payload)
        }
    }

    func testFileSourceMissingFileThrows() {
        let bogus = URL(fileURLWithPath: "/tmp/audd-does-not-exist-\(UUID().uuidString).bin")
        do {
            _ = try prepareSource(.file(bogus))
            XCTFail("expected throw")
        } catch AudDError.invalidArgument {
            // ok
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testStreamSourceFirstAttemptOK_SecondReusesCachedBuffer() throws {
        let payload = "streamed bytes".data(using: .utf8)!
        let stream = InputStream(data: payload)
        let reopen = try prepareSource(.stream(stream, name: "test.bin"))
        let first = try reopen()
        XCTAssertEqual(first.filePart?.data, payload)
        XCTAssertEqual(first.filePart?.name, "test.bin")
        // Second call uses the cached buffer
        let second = try reopen()
        XCTAssertEqual(second.filePart?.data, payload)
    }
}
