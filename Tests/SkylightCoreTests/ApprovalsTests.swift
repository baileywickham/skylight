import XCTest
@testable import SkylightCore

final class ApprovalsTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("approvals-\(UUID().uuidString).json")
    }

    func testMissingFileMeansAllowAll() {
        let approvals = Approvals(fileURL: tempFile()) // never written
        XCTAssertEqual(approvals.load(), ApprovalsConfig(mode: "allow_all", allow: []))
        XCTAssertNoThrow(try approvals.check(name: "TextEdit", bundleID: "com.apple.TextEdit"))
    }

    func testAllowlistMatchingIsCaseInsensitiveOnNameAndBundleID() {
        let cfg = ApprovalsConfig(mode: "allowlist", allow: ["textedit", "COM.APPLE.FINDER"])
        XCTAssertTrue(Approvals.isAllowed(config: cfg, name: "TextEdit", bundleID: nil))
        XCTAssertTrue(Approvals.isAllowed(config: cfg, name: "Finder", bundleID: "com.apple.finder"))
        XCTAssertFalse(Approvals.isAllowed(config: cfg, name: "Safari", bundleID: "com.apple.Safari"))
        XCTAssertTrue(Approvals.isAllowed(config: ApprovalsConfig(mode: "allowlist", allow: ["*"]),
                                          name: "Anything", bundleID: nil))
    }

    func testCheckThrowsApprovalRequiredForUnlistedApp() throws {
        let url = tempFile()
        let cfg = ApprovalsConfig(mode: "allowlist", allow: ["TextEdit"])
        try JSONEncoder().encode(cfg).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let approvals = Approvals(fileURL: url)
        XCTAssertNoThrow(try approvals.check(name: "TextEdit", bundleID: nil))
        XCTAssertThrowsError(try approvals.check(name: "Safari", bundleID: "com.apple.Safari")) { error in
            XCTAssertEqual((error as? SkyServiceError)?.code, .approvalRequired)
        }
    }

    func testMalformedFileFailsOpenToAllowAll() throws {
        let url = tempFile()
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(try Approvals(fileURL: url).check(name: "Safari", bundleID: nil))
    }
}
