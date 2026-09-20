import CoreGraphics
import XCTest
import SkylightCore

/// The pure parts of the background-click path. What cannot be unit-tested —
/// whether a real app acts on the event — is covered by ts/live/fixes-check.mts.
final class BackgroundMouseTests: XCTestCase {
    private let window = CGRect(x: 384, y: 305, width: 656, height: 422)

    func testWindowLocalPointIsTopLeftOriginAndRelativeToTheWindow() {
        // CGEventSetWindowLocation takes a TOP-LEFT-origin window point; the
        // window server flips it to AppKit's bottom-left locationInWindow
        // itself. Flipping here too mirrors every click about the window's
        // midline — shipped once as v0.3.7 and caught by a click aimed at
        // clientY 81 arriving at 626.
        let topLeft = windowLocalPoint(global: CGPoint(x: 384, y: 305), windowFrame: window)
        XCTAssertEqual(topLeft.x, 0)
        XCTAssertEqual(topLeft.y, 0, "the window's top-left corner is the origin")

        let bottomLeft = windowLocalPoint(global: CGPoint(x: 384, y: 727), windowFrame: window)
        XCTAssertEqual(bottomLeft.y, 422, "the bottom edge is the window's height, not zero")

        let inside = windowLocalPoint(global: CGPoint(x: 412, y: 345), windowFrame: window)
        XCTAssertEqual(inside.x, 28)
        XCTAssertEqual(inside.y, 40)
    }

    func testAPointNearTheTopDoesNotComeBackNearTheBottom() {
        // The regression in one line: under the mirrored math these two were
        // swapped, which is exactly how a click lands in the wrong half.
        let nearTop = windowLocalPoint(global: CGPoint(x: 400, y: 315), windowFrame: window)
        let nearBottom = windowLocalPoint(global: CGPoint(x: 400, y: 717), windowFrame: window)
        XCTAssertLessThan(nearTop.y, nearBottom.y)
    }

    func testButtonEventsAreDistinguishedFromMoves() {
        // Moves must stay plain CGEvents: an NSEvent-built move stops
        // registering as a hover in Chromium (verified live).
        XCTAssertTrue(BackgroundMouse.isButtonEvent(.leftMouseDown))
        XCTAssertTrue(BackgroundMouse.isButtonEvent(.rightMouseUp))
        XCTAssertTrue(BackgroundMouse.isButtonEvent(.leftMouseDragged))
        XCTAssertFalse(BackgroundMouse.isButtonEvent(.mouseMoved),
                       "moves stay plain: hover is verified working as-is")
        XCTAssertFalse(BackgroundMouse.isButtonEvent(.scrollWheel))
    }

    func testScrollWheelIsNotAButtonEvent() {
        // Why background scroll is refused rather than stamped and posted.
        XCTAssertFalse(BackgroundMouse.isButtonEvent(.scrollWheel))
        XCTAssertNil(BackgroundMouse.event(type: .scrollWheel, global: .zero, windowID: 7,
                                           windowFrame: window, button: .left, clickCount: 1))
    }

    func testWindowIDZeroIsRefused() {
        // An unidentifiable window means the event cannot name a target, and a
        // nil return is what drops the caller back to a plain CGEvent.
        XCTAssertNil(BackgroundMouse.event(type: .leftMouseDown, global: .zero, windowID: 0,
                                           windowFrame: window, button: .left, clickCount: 1))
    }

    func testBackgroundPointerNeedsBothCapabilities() {
        // Capability-driven, not app-driven: what matters is whether this
        // machine can stamp the event AND make the target active without
        // raising it. Both are load-bearing — a fully stamped click posted into
        // a genuinely inactive app is dropped, and lands once the flip has run.
        // (An earlier version refused everything outside the Chromium family,
        // which was an artifact of the mirrored coordinate bug above.)
        XCTAssertTrue(backgroundPointerReaches(stampAvailable: true, canFocusWithoutRaise: true))
        XCTAssertFalse(backgroundPointerReaches(stampAvailable: true, canFocusWithoutRaise: false),
                       "a stamped click into an app that is not active does nothing")
        XCTAssertFalse(backgroundPointerReaches(stampAvailable: false, canFocusWithoutRaise: true),
                       "without the stamp the event reaches no window")
        XCTAssertFalse(backgroundPointerReaches(stampAvailable: false, canFocusWithoutRaise: false))
    }
}
