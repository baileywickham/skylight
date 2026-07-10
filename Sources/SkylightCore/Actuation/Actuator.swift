import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Performs the API's actions against live apps. NOT thread-safe (it shares
/// AXCapture's per-app index map): all calls must stay on the daemon's global
/// serial actuation queue, where the router already runs handlers.
public final class Actuator {
    private let registry: AppRegistry
    private let capture: AXCapture
    private let postActionSleepMs: Int
    private let pauseFile: URL

    public init(registry: AppRegistry, capture: AXCapture,
                postActionSleepMs: Int = 100, pauseFile: URL = SkylightPaths.pauseFile) {
        self.registry = registry
        self.capture = capture
        self.postActionSleepMs = postActionSleepMs
        self.pauseFile = pauseFile
    }

    // MARK: - Shared plumbing

    private func guardNotPaused() throws {
        if FileManager.default.fileExists(atPath: pauseFile.path) {
            throw SkyServiceError(code: .actuationPaused,
                                  message: "actuation paused by \(pauseFile.path); remove the file to resume")
        }
    }

    /// UI repaint pause after successful actions (Sky default: 100ms).
    private func postActionSleep() {
        if postActionSleepMs > 0 { usleep(UInt32(postActionSleepMs) * 1000) }
    }

    private func mapAXError(_ err: AXError, action: String) -> SkyServiceError {
        switch err {
        case .invalidUIElement:
            return SkyServiceError(code: .elementNotActionable,
                                   message: "\(action): backing AXUIElement is dead — call get_app_state and retry")
        case .actionUnsupported, .attributeUnsupported, .noValue:
            return SkyServiceError(code: .elementNotActionable,
                                   message: "\(action): element no longer supports this action")
        case .apiDisabled:
            return SkyServiceError(code: .permissionDenied,
                                   message: "Accessibility not granted: enable SkylightService in System Settings > Privacy & Security > Accessibility")
        default:
            return SkyServiceError(code: .elementNotActionable, message: "\(action) failed (AXError \(err.rawValue))")
        }
    }

    private func mouseButton(_ name: String?) throws -> (button: CGMouseButton, down: CGEventType, up: CGEventType, drag: CGEventType) {
        switch name ?? "left" {
        case "left": return (.left, .leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case "right": return (.right, .rightMouseDown, .rightMouseUp, .rightMouseDragged)
        case "middle": return (.center, .otherMouseDown, .otherMouseUp, .otherMouseDragged)
        default: throw SkyServiceError(code: .invalidParams, message: "mouse_button must be left|right|middle")
        }
    }

    /// Resolves app + raised window; geometry from the latest capture for coordinate math.
    /// Geometry is checked BEFORE the live focusedWindow AX call so a missing
    /// prior capture fails fast with invalid_params without touching AX.
    private func target(_ appIdentifier: String, needsGeometry: Bool) throws
        -> (app: NSRunningApplication, window: AXUIElement, geometry: CaptureGeometry?) {
        let app = try registry.resolve(appIdentifier)
        var geometry: CaptureGeometry?
        if needsGeometry {
            guard let g = capture.latestGeometry(forPid: app.processIdentifier) else {
                throw SkyServiceError(code: .invalidParams,
                                      message: "no prior capture for '\(appIdentifier)' — coordinates are screenshot pixels; call get_app_state first")
            }
            geometry = g
        }
        let window = try capture.focusedWindow(of: app)
        return (app, window, geometry)
    }

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Actions

    public func click(_ input: ClickInput) throws -> ActionResult {
        try guardNotPaused()
        _ = try mouseButton(input.mouse_button) // validate early
        if let index = input.element_index {
            let app = try registry.resolve(input.app)
            let element = try capture.element(forIndex: index, appPid: app.processIdentifier)
            let window = try capture.focusedWindow(of: app)
            activateAndRaise(app: app, window: window) // unobscured post-action screenshots
            let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
            guard err == .success else { throw mapAXError(err, action: "click[\(index)]") }
        } else if let x = input.x, let y = input.y {
            let (app, window, geometry) = try target(input.app, needsGeometry: true)
            activateAndRaise(app: app, window: window)
            let point = globalPoint(fromScreenshotX: x, y: y, geometry: geometry!)
            let (button, down, up, _) = try mouseButton(input.mouse_button)
            let clicks = input.click_count ?? 1
            for i in 1...max(clicks, 1) {
                let downEvent = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: button)
                let upEvent = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: button)
                downEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                upEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                post(downEvent)
                post(upEvent)
            }
        } else {
            throw SkyServiceError(code: .invalidParams, message: "click needs element_index or x+y")
        }
        postActionSleep()
        return ActionResult(done: true)
    }

    public func pressKey(_ input: PressKeyInput) throws -> ActionResult {
        try guardNotPaused()
        let chord = try parseKeyChord(input.keys)
        let (app, window, _) = try target(input.app, needsGeometry: false)
        activateAndRaise(app: app, window: window)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: chord.keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: chord.keyCode, keyDown: false)
        down?.flags = chord.flags
        up?.flags = chord.flags
        post(down)
        post(up)
        postActionSleep()
        return ActionResult(done: true)
    }

    public func typeText(_ input: TypeTextInput) throws -> ActionResult {
        try guardNotPaused()
        let (app, window, _) = try target(input.app, needsGeometry: false)
        activateAndRaise(app: app, window: window)
        // Unicode key events into current focus, 20 UTF-16 units per event.
        let units = Array(input.text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            post(down)
            post(up)
            i += 20
            usleep(5_000) // keep event order stable for fast typists
        }
        postActionSleep()
        return ActionResult(done: true)
    }

    public func scroll(_ input: ScrollInput) throws -> ActionResult {
        try guardNotPaused()
        let vertical: Bool
        let sign: Double
        switch input.direction {
        case "up": vertical = true; sign = 1
        case "down": vertical = true; sign = -1
        case "left": vertical = false; sign = 1
        case "right": vertical = false; sign = -1
        default: throw SkyServiceError(code: .invalidParams, message: "direction must be up|down|left|right")
        }
        let app = try registry.resolve(input.app)
        let element = try capture.element(forIndex: input.element_index, appPid: app.processIdentifier)
        let window = try capture.focusedWindow(of: app)
        activateAndRaise(app: app, window: window)

        // Move the cursor over the element's center, then post pixel scrolls of
        // one element-height/width per page.
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            throw SkyServiceError(code: .elementNotActionable, message: "scroll[\(input.element_index)]: element has no frame")
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left))
        let page = Int32((vertical ? size.height : size.width) * sign * input.pages)
        let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: vertical ? page : 0, wheel2: vertical ? 0 : page, wheel3: 0)
        post(scrollEvent)
        postActionSleep()
        return ActionResult(done: true)
    }

    public func setValue(_ input: SetValueInput) throws -> ActionResult {
        try guardNotPaused()
        let app = try registry.resolve(input.app)
        let element = try capture.element(forIndex: input.element_index, appPid: app.processIdentifier)
        let window = try capture.focusedWindow(of: app)
        activateAndRaise(app: app, window: window)
        let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, input.value as CFString)
        guard err == .success else { throw mapAXError(err, action: "set_value[\(input.element_index)]") }
        postActionSleep()
        return ActionResult(done: true)
    }

    public func drag(_ input: DragInput) throws -> ActionResult {
        try guardNotPaused()
        let (button, down, up, dragged) = try mouseButton(input.mouse_button)
        let (app, window, geometry) = try target(input.app, needsGeometry: true)
        activateAndRaise(app: app, window: window)
        let from = globalPoint(fromScreenshotX: input.from_x, y: input.from_y, geometry: geometry!)
        let to = globalPoint(fromScreenshotX: input.to_x, y: input.to_y, geometry: geometry!)
        post(CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: from, mouseButton: button))
        let steps = 12
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let mid = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            post(CGEvent(mouseEventSource: nil, mouseType: dragged, mouseCursorPosition: mid, mouseButton: button))
            usleep(15_000)
        }
        post(CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: to, mouseButton: button))
        postActionSleep()
        return ActionResult(done: true)
    }

    public func performSecondaryAction(_ input: PerformSecondaryActionInput) throws -> ActionResult {
        try guardNotPaused()
        let app = try registry.resolve(input.app)
        let element = try capture.element(forIndex: input.element_index, appPid: app.processIdentifier)
        let window = try capture.focusedWindow(of: app)
        activateAndRaise(app: app, window: window)
        let err = AXUIElementPerformAction(element, input.action as CFString)
        guard err == .success else { throw mapAXError(err, action: "perform_secondary_action(\(input.action))") }
        postActionSleep()
        return ActionResult(done: true)
    }

    /// Milestone 1: structured not_implemented. Milestone 2 (Task 18) replaces
    /// this body with kAXSelectedTextRangeAttribute selection.
    public func selectText(_ input: SelectTextInput) throws -> ActionResult {
        try guardNotPaused()
        throw SkyServiceError(code: .notImplemented,
                              message: "select_text ships in milestone 2; use click + press_key meanwhile")
    }
}
