import XCTest
@testable import SkylightCore

final class WebAreaEnablementTests: XCTestCase {
    private func lines(_ texts: [String]) -> [TreeLine] {
        texts.enumerated().map { TreeLine(index: $0.offset, depth: 0, text: $0.element) }
    }

    func testWebAreaDetection() {
        XCTAssertTrue(hasWebArea(lines(["[0] AXWindow", "[1] AXWebArea \"docs\""])))
        XCTAssertFalse(hasWebArea(lines(["[0] AXWindow", "[1] AXButton \"Save\""])))
        XCTAssertFalse(hasWebArea([]))
    }

    /// The case this exists for: a Chromium window that published a tree and
    /// then lost it while backgrounded.
    func testReapplyWhenAWebAreaDisappears() {
        XCTAssertTrue(shouldReapplyEnablement(previouslyHadWebArea: true, currentHasWebArea: false))
    }

    /// Native apps never had a web area, so they must not pay for a re-enable
    /// (and its 300ms settle) on every single capture.
    func testNativeAppsNeverReapply() {
        XCTAssertFalse(shouldReapplyEnablement(previouslyHadWebArea: false, currentHasWebArea: false))
    }

    func testHealthyTreesDoNotReapply() {
        XCTAssertFalse(shouldReapplyEnablement(previouslyHadWebArea: true, currentHasWebArea: true))
        XCTAssertFalse(shouldReapplyEnablement(previouslyHadWebArea: false, currentHasWebArea: true))
    }

    /// The first-capture retry stays keyed to enablement only, so it cannot
    /// fire on every native-app capture.
    func testFirstCaptureRetryOnlyAppliesAtEnablement() {
        let empty = lines(["[0] AXWindow"])
        XCTAssertTrue(needsWebAreaRetry(enablementJustApplied: true, lines: empty))
        XCTAssertFalse(needsWebAreaRetry(enablementJustApplied: false, lines: empty))
    }
}
