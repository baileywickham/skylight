import AppKit
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

/// Pixels-per-point for a capture of `pointSize`: `preferred` (the backing
/// scale, or 1 for a display shot) unless the longest side would exceed
/// `maxDimension`, in which case the image is shrunk to fit. Pure so the
/// downscale policy is a table in the tests.
public func captureScale(pointSize: CGSize, preferred: Double, maxDimension: Int?) -> Double {
    let longest = max(pointSize.width, pointSize.height)
    guard let maxDimension, maxDimension > 0, longest > 0 else { return preferred }
    return min(preferred, Double(maxDimension) / longest)
}

/// Global point of a pixel in a display screenshot. Same contract as
/// `globalPoint(fromScreenshotX:y:geometry:)`: origin + px / scale.
public func displayGlobalPoint(x: Double, y: Double, geometry: CaptureGeometry) -> CGPoint {
    globalPoint(fromScreenshotX: x, y: y, geometry: geometry)
}

/// Geometry of the latest `screenshot` per display, so click/drag with a
/// display_id convert pixels against the image the model actually saw — the
/// display analogue of AXCapture's per-app latestGeometry. Lock-guarded:
/// display captures are keyed "$display" while background actions are keyed
/// per app, so a write and a read can overlap.
public final class DisplayGeometryStore {
    private var byDisplay: [CGDirectDisplayID: CaptureGeometry] = [:]
    private let lock = NSLock()

    public init() {}

    public func commit(_ geometry: CaptureGeometry, forDisplay id: CGDirectDisplayID) {
        lock.lock(); defer { lock.unlock() }
        byDisplay[id] = geometry
    }

    public func latest(forDisplay id: CGDirectDisplayID) -> CaptureGeometry? {
        lock.lock(); defer { lock.unlock() }
        return byDisplay[id]
    }
}

/// Every attached display, in CG order (main display first).
public func listDisplays() -> ListDisplaysResult {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    let main = CGMainDisplayID()
    let displays = ids.prefix(Int(count)).map { id -> DisplayInfo in
        let bounds = CGDisplayBounds(id)
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        return DisplayInfo(display_id: Int(id), width: bounds.width, height: bounds.height,
                           origin_x: bounds.origin.x, origin_y: bounds.origin.y,
                           backing_scale: screen.map { Double($0.backingScaleFactor) } ?? 2.0,
                           is_main: id == main, name: screen?.localizedName)
    }
    return ListDisplaysResult(displays: displays)
}

public final class Screenshotter {
    private let shotsDir: URL
    private var shotCounter = 0
    public let displayGeometry: DisplayGeometryStore

    public init(shotsDir: URL, displayGeometry: DisplayGeometryStore = DisplayGeometryStore()) {
        self.shotsDir = shotsDir
        self.displayGeometry = displayGeometry
    }

    private func requireScreenRecording() throws {
        guard Permissions.status().screen_recording else {
            let instructions = Permissions.instructions(
                for: PermissionStatus(accessibility: true, screen_recording: false))
            throw SkyServiceError(code: .permissionDenied, message: instructions.joined(separator: " "))
        }
    }

    private func writeShot(_ image: CGImage, prefix: String) throws -> URL {
        try FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        shotCounter += 1
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = shotsDir.appendingPathComponent("\(prefix)-\(stamp)-\(shotCounter).png")
        try writePNG(image, to: url)
        return url
    }

    // MARK: - Displays

    private func resolveDisplay(_ id: Int?, in content: SCShareableContent) throws -> SCDisplay {
        let wanted = id.map { CGDirectDisplayID($0) } ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == wanted }) else {
            let known = content.displays.map { String($0.displayID) }.joined(separator: ", ")
            throw SkyServiceError(code: .invalidParams,
                                  message: "display \(wanted) not found; call list_displays (known: \(known))")
        }
        return display
    }

    private func backingScale(of display: SCDisplay) -> Double {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }.map { Double($0.backingScaleFactor) } ?? 2.0
    }

    /// Whole-display capture. Default 1 px per point (a Retina display is
    /// captured at half its native pixel size), so pixel (x,y) is point
    /// (origin + x, origin + y) — the geometry is committed for click/drag
    /// with `display_id`.
    public func captureDisplay(_ input: ScreenshotInput) async throws -> DisplayScreenshotResult {
        try requireScreenRecording()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = try resolveDisplay(input.display_id, in: content)
        let frame = display.frame
        let scale = captureScale(pointSize: frame.size, preferred: 1.0, maxDimension: input.max_dimension)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = max(1, Int((frame.width * scale).rounded()))
        config.height = max(1, Int((frame.height * scale).rounded()))
        config.showsCursor = input.show_cursor ?? true
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        // SCK may round the requested size; derive the scale from what came back.
        let actualScale = frame.width > 0 ? Double(image.width) / frame.width : scale
        let geometry = CaptureGeometry(windowOriginX: frame.origin.x, windowOriginY: frame.origin.y, scale: actualScale)
        let url = try writeShot(image, prefix: "display-\(display.displayID)")
        displayGeometry.commit(geometry, forDisplay: display.displayID)
        return DisplayScreenshotResult(
            display_id: Int(display.displayID), url: url.absoluteString,
            data_url: input.include_data_url ?? false ? try pngDataURL(image) : nil,
            width: image.width, height: image.height, scale: actualScale,
            origin_x: frame.origin.x, origin_y: frame.origin.y)
    }

    /// Region capture at native resolution for reading small text. The region
    /// is given in pixels of the latest `screenshot` of the display (points if
    /// there was none). Read-only: it does NOT change the click geometry, so
    /// coordinates for click/drag keep referring to the last `screenshot`.
    public func zoom(_ input: ZoomInput) async throws -> DisplayScreenshotResult {
        try requireScreenRecording()
        guard input.width > 0, input.height > 0 else {
            throw SkyServiceError(code: .invalidParams, message: "zoom: width and height must be positive")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = try resolveDisplay(input.display_id, in: content)
        let frame = display.frame
        let base = displayGeometry.latest(forDisplay: display.displayID)
            ?? CaptureGeometry(windowOriginX: frame.origin.x, windowOriginY: frame.origin.y, scale: 1.0)
        let topLeft = displayGlobalPoint(x: input.x, y: input.y, geometry: base)
        let sizePts = CGSize(width: input.width / base.scale, height: input.height / base.scale)
        // sourceRect is in the display's own point space (origin at its top-left).
        let local = CGRect(x: topLeft.x - frame.origin.x, y: topLeft.y - frame.origin.y,
                           width: sizePts.width, height: sizePts.height)
            .intersection(CGRect(origin: .zero, size: frame.size))
        guard !local.isEmpty else {
            throw SkyServiceError(code: .invalidParams, message: "zoom: region lies outside display \(display.displayID)")
        }
        let scale = captureScale(pointSize: local.size, preferred: backingScale(of: display),
                                 maxDimension: input.max_dimension)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = max(1, Int((local.width * scale).rounded()))
        config.height = max(1, Int((local.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let actualScale = local.width > 0 ? Double(image.width) / local.width : scale
        let url = try writeShot(image, prefix: "zoom-\(display.displayID)")
        return DisplayScreenshotResult(
            display_id: Int(display.displayID), url: url.absoluteString,
            data_url: input.include_data_url ?? false ? try pngDataURL(image) : nil,
            width: image.width, height: image.height, scale: actualScale,
            origin_x: frame.origin.x + local.origin.x, origin_y: frame.origin.y + local.origin.y)
    }

    // MARK: - Windows

    /// Window crop. Returns the image plus the pixels-per-point it was
    /// captured at, which the caller commits as the click geometry (the one
    /// source of truth for both — see the coordinate contract).
    public func capture(window: AXUIElement, includeDataURL: Bool,
                        maxDimension: Int? = nil) async throws -> ScreenshotResult {
        try requireScreenRecording()
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
            var pid: pid_t = 0
            AXUIElementGetPid(window, &pid)
            let role: String = axAttribute(window, kAXRoleAttribute) ?? "?"
            let frame = axFrame(of: window).map { "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? "noframe"
            let samePid = content.windows.filter { $0.owningApplication?.processID == pid }
                .map { "id=\($0.windowID) \(Int($0.frame.origin.x)),\(Int($0.frame.origin.y)) \(Int($0.frame.width))x\(Int($0.frame.height))" }
            throw SkyServiceError(code: .captureFailed,
                                  message: "cannot resolve CGWindowID (bridge=\(axWindowID(of: window).map(String.init) ?? "nil") role=\(role) frame=\(frame) pid=\(pid) samePidWindows=\(samePid))")
        }
        let backing = scWindow.frame.width > 0
            ? Double((try? captureGeometry(for: window))?.scale ?? 2.0) : 2.0
        let scale = captureScale(pointSize: scWindow.frame.size, preferred: backing, maxDimension: maxDimension)
        // desktopIndependentWindow crops the capture to exactly this window,
        // so PNG pixel (0,0) is the window's top-left — the coordinate contract.
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = max(1, Int((scWindow.frame.width * scale).rounded()))
        config.height = max(1, Int((scWindow.frame.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let actualScale = scWindow.frame.width > 0 ? Double(image.width) / scWindow.frame.width : scale
        let url = try writeShot(image, prefix: "shot")
        return ScreenshotResult(
            url: url.absoluteString,
            data_url: includeDataURL ? try pngDataURL(image) : nil,
            width: image.width,
            height: image.height,
            scale: actualScale)
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
