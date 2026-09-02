import ApplicationServices
import CoreGraphics
import XCTest
import SkylightCore

final class ScreenshotterTests: XCTestCase {
    private func solidImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testPrivateBridgeSymbolResolves() {
        // The dlsym lookup itself must succeed on this OS; calling it on a fake
        // window would need permissions, but symbol presence is the load-bearing risk.
        XCTAssertNotNil(dlsym(dlopen(nil, RTLD_NOW), "_AXUIElementGetWindow"),
                        "_AXUIElementGetWindow gone — implement the frame/title fallback from the spec")
    }

    func testWritePNGProducesReadablePNGFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skylight-shots-\(UUID())")
        let url = dir.appendingPathComponent("shot.png")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writePNG(solidImage(width: 8, height: 4), to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual([UInt8](data.prefix(4)), [0x89, 0x50, 0x4E, 0x47]) // PNG magic
    }

    func testDataURLIsBase64PNG() throws {
        let dataURL = try pngDataURL(solidImage(width: 2, height: 2))
        XCTAssertTrue(dataURL.hasPrefix("data:image/png;base64,"))
        let payload = String(dataURL.dropFirst("data:image/png;base64,".count))
        XCTAssertNotNil(Data(base64Encoded: payload))
    }

    func testAwaitResultBridgesAsyncToSync() throws {
        let value = try awaitResult { () async throws -> Int in
            try await Task.sleep(nanoseconds: 10_000_000)
            return 42
        }
        XCTAssertEqual(value, 42)
    }

    // MARK: - Display capture policy (pure)

    func testCaptureScaleKeepsPreferredWhenItFits() {
        XCTAssertEqual(captureScale(pointSize: CGSize(width: 800, height: 600), preferred: 2.0, maxDimension: 1600), 2.0)
        XCTAssertEqual(captureScale(pointSize: CGSize(width: 800, height: 600), preferred: 2.0, maxDimension: nil), 2.0)
        XCTAssertEqual(captureScale(pointSize: CGSize(width: 800, height: 600), preferred: 1.0, maxDimension: 0), 1.0)
    }

    func testCaptureScaleShrinksLongestSideToFit() {
        // 1728x1117 points at 1x with a 1568 cap: 1568/1728.
        let s = captureScale(pointSize: CGSize(width: 1728, height: 1117), preferred: 1.0, maxDimension: 1568)
        XCTAssertEqual(s, 1568.0 / 1728.0, accuracy: 1e-9)
        // Portrait: the height is the longest side.
        let p = captureScale(pointSize: CGSize(width: 500, height: 3000), preferred: 2.0, maxDimension: 1500)
        XCTAssertEqual(p, 0.5, accuracy: 1e-9)
    }

    func testDisplayGlobalPointUsesOriginPlusPixelsOverScale() {
        let g = CaptureGeometry(windowOriginX: 1728, windowOriginY: -200, scale: 0.5)
        let pt = displayGlobalPoint(x: 100, y: 50, geometry: g)
        XCTAssertEqual(pt.x, 1728 + 200)
        XCTAssertEqual(pt.y, -200 + 100)
    }

    func testDisplayGeometryStoreIsPerDisplay() {
        let store = DisplayGeometryStore()
        XCTAssertNil(store.latest(forDisplay: 1))
        store.commit(CaptureGeometry(windowOriginX: 0, windowOriginY: 0, scale: 1), forDisplay: 1)
        store.commit(CaptureGeometry(windowOriginX: 10, windowOriginY: 0, scale: 2), forDisplay: 2)
        XCTAssertEqual(store.latest(forDisplay: 1)?.scale, 1)
        XCTAssertEqual(store.latest(forDisplay: 2)?.windowOriginX, 10)
        XCTAssertNil(store.latest(forDisplay: 3))
    }

    func testListDisplaysReportsTheMainDisplay() {
        let displays = listDisplays().displays
        XCTAssertFalse(displays.isEmpty)
        XCTAssertEqual(displays.filter(\.is_main).count, 1)
        XCTAssertTrue(displays.allSatisfy { $0.width > 0 && $0.height > 0 && $0.backing_scale > 0 })
    }

    func testFileURLWithSpaceInPath() throws {
        let dirName = "skylight test dir"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(dirName)
        let url = dir.appendingPathComponent("shot with space.png")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writePNG(solidImage(width: 8, height: 4), to: url)

        // Test that absoluteString produces a valid file:// URL with percent-encoding
        let fileURL = url.absoluteString
        XCTAssertTrue(fileURL.hasPrefix("file://"))

        // Verify round-tripping: the URL string should decode back to the actual path
        let decodedURL = URL(string: fileURL)
        XCTAssertNotNil(decodedURL)
        XCTAssertEqual(decodedURL!.path, url.path)

        // Verify the file exists at the decoded path
        XCTAssertTrue(FileManager.default.fileExists(atPath: decodedURL!.path))

        // Clean up
        try FileManager.default.removeItem(at: dir)
    }
}
