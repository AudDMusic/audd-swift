// Smoke tests — validate the package builds and basic types work.
import XCTest
@testable import AudD

final class SmokeTests: XCTestCase {
    func testVersionExposed() {
        let version = AudDVersion.current
        XCTAssertFalse(version.isEmpty)
        XCTAssertNotNil(version.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression))
    }

    func testUserAgentFormat() {
        let ua = UserAgent.string()
        XCTAssertTrue(ua.hasPrefix("audd-swift/\(AudDVersion.current)"))
        XCTAssertTrue(ua.contains("swift/"))
    }
}
