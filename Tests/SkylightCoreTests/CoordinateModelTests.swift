import XCTest
import SkylightCore

final class CoordinateModelTests: XCTestCase {
    func testRetinaConversion() {
        // Window at global (100, 50) points on a 2x display; pixel (240, 120) in the
        // cropped screenshot is 120x60 points into the window.
        let geo = CaptureGeometry(windowOriginX: 100, windowOriginY: 50, scale: 2)
        let p = globalPoint(fromScreenshotX: 240, y: 120, geometry: geo)
        XCTAssertEqual(p.x, 220)
        XCTAssertEqual(p.y, 110)
    }

    func testNonRetinaConversionIsIdentityPlusOrigin() {
        let geo = CaptureGeometry(windowOriginX: -1440, windowOriginY: 0, scale: 1)
        let p = globalPoint(fromScreenshotX: 10, y: 20, geometry: geo)
        XCTAssertEqual(p.x, -1430)
        XCTAssertEqual(p.y, 20)
    }

    func testScreenshotOriginMapsToWindowOrigin() {
        let geo = CaptureGeometry(windowOriginX: 33, windowOriginY: 44, scale: 2)
        let p = globalPoint(fromScreenshotX: 0, y: 0, geometry: geo)
        XCTAssertEqual(p.x, 33)
        XCTAssertEqual(p.y, 44)
    }

    // MARK: - visibleScrollFrame (scroll target clamped to the window)
    //
    // Scrollable content elements report full-content-sized AX frames that can
    // extend far past the window; the wheel event must land inside the window,
    // not at the unclamped content center (which may sit over another window).

    func testElementFullyInsideWindowIsUnchanged() {
        let element = CGRect(x: 120, y: 140, width: 400, height: 300)
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(visibleScrollFrame(elementFrame: element, windowFrame: window), element)
    }

    func testTallContentFrameIsClippedToWindow() {
        // Content extends 4000pt below a 600pt window: raw center (y=2100) is
        // far outside; the visible frame's center must stay inside the window.
        let element = CGRect(x: 100, y: 100, width: 800, height: 4000)
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        let visible = visibleScrollFrame(elementFrame: element, windowFrame: window)
        XCTAssertEqual(visible, CGRect(x: 100, y: 100, width: 800, height: 600))
        XCTAssertTrue(window.contains(CGPoint(x: visible.midX, y: visible.midY)))
    }

    func testPartialOverlapUsesIntersection() {
        let element = CGRect(x: 0, y: 500, width: 500, height: 500)
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        let visible = visibleScrollFrame(elementFrame: element, windowFrame: window)
        XCTAssertEqual(visible, CGRect(x: 100, y: 500, width: 400, height: 200))
    }

    func testDisjointFramesFallBackToWindow() {
        // A stale/bogus element frame entirely off-window must not send the
        // wheel event outside the target window.
        let element = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(visibleScrollFrame(elementFrame: element, windowFrame: window), window)
    }
}
