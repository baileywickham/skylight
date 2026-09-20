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

    func testBackgroundPointerReachesTheChromiumFamilyByBundleID() {
        XCTAssertTrue(backgroundPointerReaches(bundleID: "com.google.Chrome"))
        XCTAssertFalse(backgroundPointerReaches(bundleID: "com.apple.TextEdit"),
                       "verified live: AppKit ignores the event, foreground lands instantly")
        XCTAssertFalse(backgroundPointerReaches(bundleID: nil))
    }

    func testElectronAppIsRecognizedByItsFrameworksNotItsBundleID() throws {
        // The Claude desktop app is Electron and its id says nothing about it
        // (com.anthropic.claudefordesktop) — the case that made bundle-id
        // matching alone wrong, and the app this matters most for.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("skylight-bundle-\(UUID().uuidString)")
        let frameworks = root.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(backgroundPointerReaches(bundleID: "com.anthropic.claudefordesktop"),
                       "the id alone gives nothing away")
        XCTAssertTrue(backgroundPointerReaches(bundleID: "com.anthropic.claudefordesktop", bundleURL: root))
        XCTAssertTrue(embedsChromium(bundleURL: root))
    }

    func testAnAppWithNoFrameworksIsNotChromium() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("skylight-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Contents/Frameworks/Mantle.framework"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(embedsChromium(bundleURL: root))
        XCTAssertFalse(embedsChromium(bundleURL: nil))
    }
}
