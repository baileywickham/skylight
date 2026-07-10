import XCTest
import SkylightCore

final class PermissionsTests: XCTestCase {
    func testStatusReturnsBothChecksWithoutCrashing() {
        let status = Permissions.status()
        // Cannot assert values (depends on TCC state of the test runner); assert shape.
        _ = status.accessibility
        _ = status.screen_recording
    }

    func testInstructionsNameTheExactPanes() {
        let none = PermissionStatus(accessibility: false, screen_recording: false)
        let lines = Permissions.instructions(for: none)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("System Settings > Privacy & Security > Accessibility"))
        XCTAssertTrue(lines[1].contains("System Settings > Privacy & Security > Screen & System Audio Recording"))
        XCTAssertEqual(Permissions.instructions(for: PermissionStatus(accessibility: true, screen_recording: true)), [])
    }

    func testSocketLivenessProbe() {
        XCTAssertFalse(Permissions.socketIsLive(at: "/tmp/skylight-definitely-missing.sock"))
    }
}
