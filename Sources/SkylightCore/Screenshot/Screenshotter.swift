import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw SkyServiceError(code: .captureFailed, message: "cannot create PNG at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw SkyServiceError(code: .captureFailed, message: "PNG write failed at \(url.path)")
    }
}

public func pngDataURL(_ image: CGImage) throws -> String {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw SkyServiceError(code: .captureFailed, message: "cannot encode PNG data URL")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw SkyServiceError(code: .captureFailed, message: "PNG encode failed")
    }
    return "data:image/png;base64," + (data as Data).base64EncodedString()
}

/// Runs an async operation to completion from synchronous code. Handlers run on
/// the IPC serial queue (never the main thread), so blocking here is safe.
public func awaitResult<T>(_ body: @escaping () async throws -> T) throws -> T {
    var result: Result<T, Error>!
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try result.get()
}

public final class Screenshotter {
    private let shotsDir: URL
    private var shotCounter = 0

    public init(shotsDir: URL) {
        self.shotsDir = shotsDir
    }

    public func capture(window: AXUIElement, includeDataURL: Bool) async throws -> ScreenshotResult {
        guard Permissions.status().screen_recording else {
            let instructions = Permissions.instructions(
                for: PermissionStatus(accessibility: true, screen_recording: false))
            throw SkyServiceError(code: .permissionDenied, message: instructions.joined(separator: " "))
        }
        // SCK cannot capture a minimized window; unminimize (activation-first
        // policy — actions would need it visible anyway) and let it settle.
        if let minimized: NSNumber = axAttribute(window, kAXMinimizedAttribute), minimized.boolValue {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let scWindow: SCWindow
        if let windowID = axWindowID(of: window) {
            guard let match = content.windows.first(where: { $0.windowID == windowID }) else {
                let state = "window \(windowID) not in shareable content (minimized, closing, or on a hidden Space)"
                throw SkyServiceError(code: .captureFailed, message: state)
            }
            scWindow = match
        } else if let match = fallbackSCWindow(for: window, in: content) {
            // Private-symbol bridge unavailable: best-effort frame+title match.
            scWindow = match
        } else {
            throw SkyServiceError(code: .captureFailed,
                                  message: "cannot resolve CGWindowID for the target window (bridge unavailable, no frame/title match)")
        }
        let scale = scWindow.frame.width > 0
            ? Double((try? captureGeometry(for: window))?.scale ?? 2.0) : 2.0
        // desktopIndependentWindow crops the capture to exactly this window,
        // so PNG pixel (0,0) is the window's top-left — the coordinate contract.
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = Int(scWindow.frame.width * scale)
        config.height = Int(scWindow.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        try FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        shotCounter += 1
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = shotsDir.appendingPathComponent("shot-\(stamp)-\(shotCounter).png")
        try writePNG(image, to: url)
        return ScreenshotResult(
            url: url.absoluteString,
            data_url: includeDataURL ? try pngDataURL(image) : nil,
            width: image.width,
            height: image.height)
    }

    /// Best-effort fallback when _AXUIElementGetWindow is unavailable: match the
    /// AX window's frame (top-left-origin global points, same space as
    /// SCWindow.frame) and title against shareable windows of the same pid.
    private func fallbackSCWindow(for window: AXUIElement, in content: SCShareableContent) -> SCWindow? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return nil }
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        let frame = CGRect(origin: origin, size: size)
        let title: String? = axAttribute(window, kAXTitleAttribute)

        let sameApp = content.windows.filter { $0.owningApplication?.processID == pid }
        let frameMatches = sameApp.filter {
            abs($0.frame.origin.x - frame.origin.x) <= 2 && abs($0.frame.origin.y - frame.origin.y) <= 2 &&
            abs($0.frame.width - frame.width) <= 2 && abs($0.frame.height - frame.height) <= 2
        }
        if frameMatches.count == 1 { return frameMatches.first }
        if let title, let both = frameMatches.first(where: { $0.title == title }) { return both }
        if let title, let byTitle = sameApp.first(where: { $0.title == title }) { return byTitle }
        return frameMatches.first
    }
}
