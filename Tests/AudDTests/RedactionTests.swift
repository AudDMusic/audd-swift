// The api_token must never show up when the client, its namespaces or its
// errors are printed, dumped or reflected.
import XCTest
@testable import AudD

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RedactionTests: XCTestCase {
    private let token = "redaction-secret-token-98765"

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func renderings(_ value: Any) -> [String] {
        var dumped = ""
        dump(value, to: &dumped)
        var children: [String] = []
        for child in Mirror(reflecting: value).children {
            children.append("\(child.label ?? ""): \(String(reflecting: child.value))")
        }
        return [String(describing: value), String(reflecting: value), dumped] + children
    }

    private func assertNoToken(_ value: Any, file: StaticString = #filePath, line: UInt = #line) {
        for text in renderings(value) {
            XCTAssertFalse(text.contains(token), "token visible in: \(text)", file: file, line: line)
        }
    }

    func testClientAndNamespacesDoNotShowTheToken() async throws {
        let audd = try AudD(apiToken: token)
        assertNoToken(audd)
        assertNoToken(audd.streams)
        assertNoToken(audd.customCatalog)
        assertNoToken(audd.advanced)
        XCTAssertTrue(String(describing: audd).contains("<redacted>"))

        try await audd.setApiToken(token + "-rotated")
        assertNoToken(audd)
        assertNoToken(audd.streams)
        await audd.close()
    }

    func testConnectionErrorsDoNotShowTheToken() async throws {
        let session = mockSession()
        MockURLProtocol.register { _ in throw URLError(.notConnectedToInternet) }
        let audd = try AudD(apiToken: token, maxRetries: 1, urlSession: session)
        do {
            _ = try await audd.recognize("https://audd.tech/example.mp3")
            XCTFail("expected an error")
        } catch {
            assertNoToken(error)
            XCTAssertFalse(error.localizedDescription.contains(token))
        }
        do {
            _ = try await audd.streams.list()
            XCTFail("expected an error")
        } catch {
            assertNoToken(error)
        }
        await audd.close()
    }

    func testLongpollErrorsDoNotShowTheToken() async throws {
        let session = mockSession()
        MockURLProtocol.register { _ in throw URLError(.timedOut) }
        let audd = try AudD(apiToken: token, maxRetries: 1, urlSession: session)
        let poll = try await audd.streams.longpoll(
            radioID: 3,
            options: LongpollOptions(timeout: 1, skipCallbackCheck: true)
        )
        let guardTask = watchdog(poll)
        let errors = await firstItems(poll.errors, 1)
        guardTask.cancel()
        XCTAssertEqual(errors.count, 1)
        for error in errors {
            assertNoToken(error)
            XCTAssertFalse(error.localizedDescription.contains(token))
        }
        await poll.close()
        await audd.close()
    }
}
