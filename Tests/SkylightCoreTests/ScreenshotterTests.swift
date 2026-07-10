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
}
