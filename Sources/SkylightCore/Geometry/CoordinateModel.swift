import AppKit
import ApplicationServices
import Foundation

/// Window frame + display scale recorded at capture time, so coordinates given
/// against the latest screenshot convert against the geometry that produced it.
public struct CaptureGeometry: Codable, Equatable {
    public let windowOriginX: Double
    public let windowOriginY: Double
    public let scale: Double
    public init(windowOriginX: Double, windowOriginY: Double, scale: Double) {
        self.windowOriginX = windowOriginX
        self.windowOriginY = windowOriginY
        self.scale = scale
    }
}

/// Coordinate contract: inputs are pixels of the returned (window-cropped) PNG.
/// global_point = (screenshot_px / window_backing_scale_factor) + window_origin_points
public func globalPoint(fromScreenshotX x: Double, y: Double, geometry: CaptureGeometry) -> CGPoint {
    CGPoint(x: x / geometry.scale + geometry.windowOriginX,
            y: y / geometry.scale + geometry.windowOriginY)
}

/// Shared typed AX attribute reader.
public func axAttribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

/// Reads the live window frame origin (global points, top-left origin — matching
/// CGEvent space) and the backing scale of the display the window is on.
public func captureGeometry(for window: AXUIElement) throws -> CaptureGeometry {
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
          AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success else {
        throw SkyServiceError(code: .captureFailed, message: "window has no readable frame")
    }
    var origin = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

    // AX positions are top-left-origin global coordinates; NSScreen frames are
    // bottom-left-origin. Flip to find the screen containing the window's center.
    let windowRect = CGRect(origin: origin, size: size)
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let center = CGPoint(x: windowRect.midX, y: primaryHeight - windowRect.midY)
    let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
    let scale = screen?.backingScaleFactor ?? 2.0
    return CaptureGeometry(windowOriginX: origin.x, windowOriginY: origin.y, scale: scale)
}
