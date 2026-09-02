import XCTest
import SkylightCore

final class VersionTests: XCTestCase {
    func testVersionConstant() {
        XCTAssertEqual(SkylightVersion.current, "0.3.0")
    }
}
