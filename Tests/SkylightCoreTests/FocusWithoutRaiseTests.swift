import CoreGraphics
import XCTest
@testable import SkylightCore

final class FocusWithoutRaiseTests: XCTestCase {
    private let target: CGWindowID = 0xAABBCCDD
    private let front: CGWindowID = 0x01020304

    func testCrossAppSequenceDeactivatesFrontThenActivatesTargetThenMakesItKey() {
        let steps = focusWithoutRaiseSequence(targetWindowID: target, frontWindowID: front,
                                              frontIsTarget: false)
        XCTAssertEqual(steps.count, 4, "deactivate + activate + key-window pair")
        XCTAssertEqual(steps.map(\.destination),
                       [.frontProcess, .targetProcess, .targetProcess, .targetProcess])

        XCTAssertEqual(steps[0].record[0x8a], 2, "front process is told to deactivate")
        XCTAssertEqual(Array(steps[0].record[0x3c..<0x40]), [0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(steps[1].record[0x8a], 1, "target process is told to activate")
        XCTAssertEqual(steps[2].record[0x08], 0x01, "key-window pair, first")
        XCTAssertEqual(steps[3].record[0x08], 0x02, "key-window pair, second")
    }

    /// Already-frontmost target: deactivating it and reactivating it would be a
    /// pointless flicker, so only the key-window pair is posted.
    func testSameAppSequenceOnlyMakesTheWindowKey() {
        let steps = focusWithoutRaiseSequence(targetWindowID: target, frontWindowID: front,
                                              frontIsTarget: true)
        XCTAssertEqual(steps.count, 2)
        XCTAssertTrue(steps.allSatisfy { $0.destination == .targetProcess })
        XCTAssertEqual(steps.map { $0.record[0x08] }, [0x01, 0x02])
    }

    func testEveryStepTargetsTheRequestedWindow() {
        let steps = focusWithoutRaiseSequence(targetWindowID: target, frontWindowID: front,
                                              frontIsTarget: false)
        for step in steps where step.destination == .targetProcess {
            XCTAssertEqual(Array(step.record[0x3c..<0x40]), [0xDD, 0xCC, 0xBB, 0xAA])
        }
    }

    // MARK: - Chromium user-activation primer

    func testChromiumFamilyNeedsThePrimer() {
        for bundleID in ["com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac",
                         "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
                         "com.github.Electron", "org.chromium.Chromium", "com.slack.electron"] {
            XCTAssertTrue(needsUserActivationPrimer(bundleID: bundleID), bundleID)
        }
    }

    func testAppKitAndWebKitAppsDoNot() {
        for bundleID in ["com.apple.Safari", "com.apple.TextEdit", "com.apple.finder", "com.apple.Notes"] {
            XCTAssertFalse(needsUserActivationPrimer(bundleID: bundleID), bundleID)
        }
        XCTAssertFalse(needsUserActivationPrimer(bundleID: nil))
    }

    func testPrimerPointIsOutsideAnyWindow() {
        XCTAssertLessThan(userActivationPrimerPoint.x, 0)
        XCTAssertLessThan(userActivationPrimerPoint.y, 0)
    }

    // MARK: - Which actions need input routing

    /// Only event-delivering actions pay for the focus flip; AX actions reach
    /// their element regardless of focus, so disturbing the user's front app
    /// for them would be cost without benefit.
    func testOnlyEventDeliveringActionsNeedFocus() {
        for action: ActuatorAction in [.coordinateClick, .pressKey, .typeText, .scroll, .drag] {
            XCTAssertTrue(deliversSyntheticEvents(action: action), "\(action)")
        }
        for action: ActuatorAction in [.elementClick, .setValue, .performSecondaryAction, .selectText] {
            XCTAssertFalse(deliversSyntheticEvents(action: action), "\(action)")
        }
    }
}
