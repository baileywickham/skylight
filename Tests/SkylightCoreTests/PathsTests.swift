import XCTest
import SkylightCore

final class PathsTests: XCTestCase {
    /// Regression guard for C1: the daemon is launched by launchd/`open -a`
    /// with cwd `/`, so the default shots dir must be an absolute path under
    /// the app-support dir — a cwd-relative default would make every
    /// get_app_state fail with EACCES trying to create `/.skylight/shots`.
    func testDefaultShotsDirIsAbsoluteAndUnderSupportDir() {
        let shots = SkylightPaths.shotsDir
        XCTAssertTrue(shots.path.hasPrefix("/"), "shots dir must be absolute, got \(shots.path)")
        XCTAssertTrue(shots.path.hasPrefix(SkylightPaths.supportDir.path + "/"),
                      "shots dir \(shots.path) must live under \(SkylightPaths.supportDir.path)")
        XCTAssertFalse(shots.path.contains("/./"), "shots dir must not be cwd-relative")
    }
}
