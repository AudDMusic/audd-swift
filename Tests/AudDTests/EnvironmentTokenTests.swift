// Coverage for environment-variable token pickup and runtime token rotation.
//
// Tests in this file:
//   - `AudD(apiToken: nil/empty)` falls back to AUDD_API_TOKEN
//   - `AudD.fromEnvironment()` factory
//   - `setApiToken(_:)` rotation, empty-string rejection, concurrency safety
import XCTest
@testable import AudD

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class EnvironmentTokenTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        unsetenv("AUDD_API_TOKEN")
    }

    override func tearDown() {
        unsetenv("AUDD_API_TOKEN")
        super.tearDown()
    }

    // MARK: - AUDD_API_TOKEN env-var fallback

    func testInitWithExplicitTokenIgnoresEnv() async throws {
        setenv("AUDD_API_TOKEN", "from-env", 1)
        let audd = try AudD(apiToken: "explicit")
        let token = await audd.apiToken
        XCTAssertEqual(token, "explicit")
    }

    func testInitFallsBackToEnvWhenTokenNil() async throws {
        setenv("AUDD_API_TOKEN", "from-env", 1)
        let audd = try AudD(apiToken: nil)
        let token = await audd.apiToken
        XCTAssertEqual(token, "from-env")
    }

    func testInitFallsBackToEnvWhenTokenEmpty() async throws {
        setenv("AUDD_API_TOKEN", "from-env", 1)
        let audd = try AudD(apiToken: "")
        let token = await audd.apiToken
        XCTAssertEqual(token, "from-env")
    }

    func testInitThrowsConfigurationWhenNoTokenAndNoEnv() {
        do {
            _ = try AudD(apiToken: nil)
            XCTFail("expected configuration error")
        } catch let AudDError.configuration(msg) {
            XCTAssertTrue(msg.contains("AUDD_API_TOKEN"))
            XCTAssertTrue(msg.contains("https://dashboard.audd.io"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFromEnvironmentReadsEnvVar() async throws {
        setenv("AUDD_API_TOKEN", "env-only", 1)
        let audd = try AudD.fromEnvironment()
        let token = await audd.apiToken
        XCTAssertEqual(token, "env-only")
    }

    func testFromEnvironmentThrowsWhenUnset() {
        do {
            _ = try AudD.fromEnvironment()
            XCTFail("expected configuration error")
        } catch let AudDError.configuration(msg) {
            XCTAssertTrue(msg.contains("AUDD_API_TOKEN"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - setApiToken thread-safe rotation

    func testSetApiTokenRotates() async throws {
        let audd = try AudD(apiToken: "old")
        let before = await audd.apiToken
        XCTAssertEqual(before, "old")
        try await audd.setApiToken("new")
        let after = await audd.apiToken
        XCTAssertEqual(after, "new")
    }

    func testSetApiTokenRejectsEmpty() async throws {
        let audd = try AudD(apiToken: "old")
        do {
            try await audd.setApiToken("")
            XCTFail("expected configuration error")
        } catch AudDError.configuration {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let after = await audd.apiToken
        XCTAssertEqual(after, "old")
    }

    func testSetApiTokenAffectsSubsequentRequest() async throws {
        let session = mockSession()
        let payload = "{\"status\":\"success\",\"result\":null}".data(using: .utf8)!
        let captured = TokenCapture()
        MockURLProtocol.register { request in
            // Capture the multipart body so we can confirm which token went on the wire.
            if let body = request.httpBody,
               let s = String(data: body, encoding: .utf8) {
                captured.append(s)
            } else if let stream = request.httpBodyStream {
                stream.open()
                var buf = Data()
                let bufSize = 4096
                let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                defer { bytes.deallocate() }
                while stream.hasBytesAvailable {
                    let n = stream.read(bytes, maxLength: bufSize)
                    if n <= 0 { break }
                    buf.append(bytes, count: n)
                }
                stream.close()
                if let s = String(data: buf, encoding: .utf8) {
                    captured.append(s)
                }
            }
            return (makeJSONResponse(request.url!, body: payload), payload)
        }
        let audd = try AudD(apiToken: "old-token", urlSession: session)
        _ = try await audd.recognize("https://audd.tech/example.mp3")
        try await audd.setApiToken("new-token")
        _ = try await audd.recognize("https://audd.tech/example.mp3")
        let bodies = captured.snapshot()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].contains("old-token"), "first request should carry old token")
        XCTAssertTrue(bodies[1].contains("new-token"), "second request should carry new token")
        await audd.close()
    }

    func testSetApiTokenConcurrentRotationsAreSerialized() async throws {
        // Hammer the actor with concurrent rotations + reads. The actor
        // isolation guarantee is what we're exercising — no crashes, no torn
        // reads, final value is one of the rotated tokens.
        let audd = try AudD(apiToken: "initial")
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    try? await audd.setApiToken("token-\(i)")
                }
                group.addTask {
                    _ = await audd.apiToken
                }
            }
        }
        let final = await audd.apiToken
        XCTAssertTrue(final.hasPrefix("token-"), "expected a rotated token, got \(final)")
    }
}

// MARK: - Test helper

final class TokenCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []
    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        bodies.append(s)
    }
    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return bodies
    }
}
