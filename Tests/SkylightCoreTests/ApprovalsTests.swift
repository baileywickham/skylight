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

    func testUnrecognizedModeFailsClosedToAllowlist() {
        let cfg = ApprovalsConfig(mode: "Allowlist", allow: ["TextEdit"])
        XCTAssertTrue(Approvals.isAllowed(config: cfg, name: "TextEdit", bundleID: nil))
        XCTAssertFalse(Approvals.isAllowed(config: cfg, name: "Safari", bundleID: nil))
        XCTAssertTrue(Approvals.isAllowed(config: ApprovalsConfig(mode: "ALLOW_ALL", allow: []),
                                          name: "Safari", bundleID: nil))
    }
}

final class ApprovalTierTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("approvals-\(UUID().uuidString).json")
    }

    func testTiersAreOrdered() {
        XCTAssertLessThan(ApprovalTier.read, .click)
        XCTAssertLessThan(ApprovalTier.click, .full)
    }

    func testTerminalsAndEditorsDefaultToClickEverythingElseToFull() {
        let allowAll = ApprovalsConfig(mode: "allow_all", allow: [])
        XCTAssertEqual(Approvals.tier(config: allowAll, name: "Terminal", bundleID: "com.apple.Terminal"), .click)
        XCTAssertEqual(Approvals.tier(config: allowAll, name: "iTerm2", bundleID: "com.googlecode.iterm2"), .click)
        XCTAssertEqual(Approvals.tier(config: allowAll, name: "TextEdit", bundleID: "com.apple.TextEdit"), .full)
        // A trailing "." covers the whole vendor prefix.
        XCTAssertEqual(Approvals.tier(config: allowAll, name: "PyCharm", bundleID: "com.jetbrains.pycharm"), .click)
        // Case-insensitive, and an app with no bundle id cannot match a default.
        XCTAssertEqual(Approvals.defaultTier(bundleID: "COM.APPLE.TERMINAL"), .click)
        XCTAssertEqual(Approvals.defaultTier(bundleID: nil), .full)
    }

    func testExplicitTierOverridesDefaultsAndApprovesOutsideTheAllowlist() {
        let cfg = ApprovalsConfig(mode: "allowlist", allow: ["TextEdit"],
                                  tiers: ["terminal": .full, "com.apple.Notes": .read, "TextEdit": .click])
        XCTAssertEqual(Approvals.tier(config: cfg, name: "Terminal", bundleID: "com.apple.Terminal"), .full)
        XCTAssertEqual(Approvals.tier(config: cfg, name: "Notes", bundleID: "com.apple.Notes"), .read)
        XCTAssertEqual(Approvals.tier(config: cfg, name: "TextEdit", bundleID: "com.apple.TextEdit"), .click)
        XCTAssertNil(Approvals.tier(config: cfg, name: "Safari", bundleID: "com.apple.Safari"))
    }

    func testCheckRefusesBelowTheNeededTierAndNamesTheFix() throws {
        let approvals = Approvals(fileURL: tempFile()) // allow_all, defaults only
        XCTAssertNoThrow(try approvals.check(name: "Terminal", bundleID: "com.apple.Terminal", need: .click, action: "click"))
        XCTAssertThrowsError(try approvals.check(name: "Terminal", bundleID: "com.apple.Terminal",
                                                 need: .full, action: "type_text")) { error in
            let e = error as? SkyServiceError
            XCTAssertEqual(e?.code, .approvalRequired)
            XCTAssertTrue(e?.message.contains("type_text needs full") ?? false, e?.message ?? "")
            XCTAssertTrue(e?.message.contains("skylight tier \"Terminal\" full") ?? false, e?.message ?? "")
        }
    }

    func testTierNamesDecodeCaseInsensitivelyAndOldFilesStillLoad() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"mode":"allow_all","allow":[],"tiers":{"Terminal":"Full"}}"#.utf8).write(to: url)
        XCTAssertEqual(Approvals(fileURL: url).load().tiers, ["Terminal": .full])
        // A file written before tiers existed has no key at all.
        try Data(#"{"mode":"allowlist","allow":["TextEdit"]}"#.utf8).write(to: url)
        XCTAssertNil(Approvals(fileURL: url).load().tiers)
    }

    /// One bad value must not fail the whole file: that falls back to
    /// allow_all and drops the allowlist with it.
    func testUnknownTierDropsOnlyThatEntry() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"mode":"allowlist","allow":["TextEdit"],"tiers":{"Safari":"readonly","Notes":"read"}}"#.utf8).write(to: url)
        let cfg = Approvals(fileURL: url).load()
        XCTAssertEqual(cfg.mode, "allowlist")
        XCTAssertEqual(cfg.allow, ["TextEdit"])
        XCTAssertEqual(cfg.tiers, ["Notes": .read])
    }

    func testEditingRefusesAFileThatDoesNotParse() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(try Approvals(fileURL: url).loadForEditing())
        try Data("{not json".utf8).write(to: url)
        XCTAssertThrowsError(try Approvals(fileURL: url).loadForEditing())
    }

    func testClickTierDependsOnButtonAndModifiers() {
        XCTAssertEqual(requiredClickTier(mouseButton: nil, hasModifiers: false), .click)
        XCTAssertEqual(requiredClickTier(mouseButton: "left", hasModifiers: false), .click)
        XCTAssertEqual(requiredClickTier(mouseButton: "right", hasModifiers: false), .full)
        XCTAssertEqual(requiredClickTier(mouseButton: "middle", hasModifiers: false), .full)
        XCTAssertEqual(requiredClickTier(mouseButton: "left", hasModifiers: true), .full)
    }
}
