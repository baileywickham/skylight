import AppKit
import CoreGraphics
import XCTest
import SkylightCore

/// The pure parts of the background-click path. What cannot be unit-tested —
/// whether a real app acts on the event — is covered by ts/live/fixes-check.mts.
final class BackgroundMouseTests: XCTestCase {
    private let window = CGRect(x: 384, y: 305, width: 656, height: 422)

    func testWindowLocalPointFlipsTheYAxisAndIsRelativeToTheWindow() {
        // AppKit's locationInWindow has its origin at the window's BOTTOM left;
        // a CG global point measures down from the top of the display.
        let topLeft = windowLocalPoint(global: CGPoint(x: 384, y: 305), windowFrame: window)
        XCTAssertEqual(topLeft.x, 0)
        XCTAssertEqual(topLeft.y, 422, "the window's top edge is its maximum local y")

        let bottomLeft = windowLocalPoint(global: CGPoint(x: 384, y: 727), windowFrame: window)
        XCTAssertEqual(bottomLeft.x, 0)
        XCTAssertEqual(bottomLeft.y, 0)

        let inside = windowLocalPoint(global: CGPoint(x: 412, y: 345), windowFrame: window)
        XCTAssertEqual(inside.x, 28)
        XCTAssertEqual(inside.y, 382)
    }

    func testButtonEventsAreDistinguishedFromMoves() {
        // Moves must stay plain CGEvents: an NSEvent-built move stops
        // registering as a hover in Chromium (verified live).
        XCTAssertTrue(BackgroundMouse.isButtonEvent(.leftMouseDown))
        XCTAssertTrue(BackgroundMouse.isButtonEvent(.rightMouseUp))
        XCTAssertTrue(BackgroundMouse.isButtonEvent(.leftMouseDragged))
        XCTAssertFalse(BackgroundMouse.isButtonEvent(.mouseMoved))
        XCTAssertFalse(BackgroundMouse.isButtonEvent(.scrollWheel))
    }

    func testScrollWheelHasNoNSEventEquivalent() {
        // Why background scroll is refused rather than posted.
        XCTAssertNil(BackgroundMouse.nsType(for: .scrollWheel))
        XCTAssertEqual(BackgroundMouse.nsType(for: .otherMouseDown), .otherMouseDown)
    }

    func testWindowIDZeroIsRefused() {
        // An unidentifiable window means the event cannot name a target, and a
        // nil return is what drops the caller back to a plain CGEvent.
        XCTAssertNil(BackgroundMouse.event(type: .leftMouseDown, global: .zero, windowID: 0,
                                           windowFrame: window, button: .left, clickCount: 1))
    }

    func testBackgroundPointerReachesOnlyTheChromiumFamily() {
        XCTAssertTrue(backgroundPointerReaches(bundleID: "com.google.Chrome"))
        XCTAssertTrue(backgroundPointerReaches(bundleID: "com.anthropic.claudefordesktop"),
                      "Electron shells embed the same renderer")
        XCTAssertFalse(backgroundPointerReaches(bundleID: "com.apple.TextEdit"),
                       "verified live: AppKit ignores the event, foreground lands instantly")
        XCTAssertFalse(backgroundPointerReaches(bundleID: nil))
    }
}
