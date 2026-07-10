import XCTest
import SkylightCore

final class AppRegistryTests: XCTestCase {
    func testListAppsReturnsRunningRegularApps() {
        let result = AppRegistry().listApps()
        XCTAssertFalse(result.apps.isEmpty, "at least one regular app (Finder) is always running")
        XCTAssertTrue(result.apps.allSatisfy { $0.pid > 0 })
        XCTAssertTrue(result.apps.contains { $0.bundle_id == "com.apple.finder" })
    }

    func testResolveByBundleId() throws {
        let app = try AppRegistry().resolve("com.apple.finder")
        XCTAssertEqual(app.bundleIdentifier, "com.apple.finder")
    }

    func testResolveByNameCaseInsensitive() throws {
        let app = try AppRegistry().resolve("finder")
        XCTAssertEqual(app.bundleIdentifier, "com.apple.finder")
    }

    func testResolveUnknownAppThrowsAppNotFound() {
        XCTAssertThrowsError(try AppRegistry().resolve("Definitely Not An App 9000")) { error in
            XCTAssertEqual((error as? SkyServiceError)?.code, .appNotFound)
        }
    }
}
