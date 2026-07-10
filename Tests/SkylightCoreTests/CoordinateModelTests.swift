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
}
