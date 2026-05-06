// Smoke tests — validate the package builds and basic types work.
import XCTest
@testable import AudD

final class SmokeTests: XCTestCase {
    func testVersionExposed() {
        XCTAssertEqual(AudDVersion.current, "1.4.5")
    }

    func testUserAgentFormat() {
        let ua = UserAgent.string()
        XCTAssertTrue(ua.hasPrefix("audd-swift/1.4.5"))
        XCTAssertTrue(ua.contains("swift/"))
    }
}
