import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Splits `text` into UTF-16 chunks of at most `maxUnits` units for
/// keyboardSetUnicodeString, never ending a chunk between a high surrogate
/// (0xD800–0xDBFF) and its low surrogate: a pair split across two key events
/// reaches the app as two lone surrogates and renders as U+FFFD or is dropped.
/// A chunk may therefore carry `maxUnits + 1` units when a pair straddles the
/// boundary. Concatenating the chunks always round-trips `text` exactly.
public func utf16Chunks(_ text: String, maxUnits: Int = 20) -> [[UInt16]] {
    precondition(maxUnits > 0, "maxUnits must be positive")
    let units = Array(text.utf16)
    var chunks: [[UInt16]] = []
    var start = 0
    while start < units.count {
        var end = min(start + maxUnits, units.count)
        if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) {
            end += 1 // keep the surrogate pair in this chunk
        }
        chunks.append(Array(units[start..<end]))
        start = end
    }
    return chunks
}

/// Splits a total pixel scroll into same-sign steps of at most `maxStep` px.
/// One synthesized wheel event carrying a whole page of delta is silently
/// dropped by the window server often enough to make scroll flaky (verified
/// live); a burst of small deltas — like a physical wheel — lands reliably.
public func scrollDeltas(total: Int32, maxStep: Int32 = 80) -> [Int32] {
    precondition(maxStep > 0, "maxStep must be positive")
    guard total != 0 else { return [] }
    let sign: Int32 = total > 0 ? 1 : -1
    var remaining = abs(total)
    var steps: [Int32] = []
    while remaining > 0 {
        let step = min(remaining, maxStep)
        steps.append(step * sign)
        remaining -= step
    }
    return steps
}

/// Performs the API's actions against live apps. NOT thread-safe (it shares
/// AXCapture's per-app index map): all calls must stay on the daemon's global
/// serial actuation queue, where the router already runs handlers.
public final class Actuator {
    private let registry: AppRegistry
    private let capture: AXCapture
    private let postActionSleepMs: Int
    private let pauseFile: URL
    /// Background mode (SKYLIGHT_BACKGROUND=1): never activate the target app,
    /// and deliver synthetic events per-pid so actions don't steal the user's
    /// focus. Default OFF = the activation-first behavior, unchanged.
    private let background: Bool

    public init(registry: AppRegistry, capture: AXCapture,
                postActionSleepMs: Int = 100, pauseFile: URL = SkylightPaths.pauseFile,
                background: Bool = false) {
        self.registry = registry
        self.capture = capture
        self.postActionSleepMs = postActionSleepMs
        self.pauseFile = pauseFile
        self.background = background
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

    /// Foreground (default) mode only: bring the target frontmost so session
    /// events land in it and post-action screenshots are unobscured. In
    /// background mode this is a no-op for EVERY action — AX element actions
    /// need no focus at all, and synthetic events are routed per-pid instead.
    private func raiseUnlessBackground(app: NSRunningApplication, window: AXUIElement) {
        guard shouldActivate(background: background) else { return }
        activateAndRaise(app: app, window: window)
    }

    /// Delivers a synthetic event. Default: session HID tap (frontmost app).
    /// Background mode: CGEventPostToPid into `pid`'s event queue, so the
    /// event reaches the target even while another app holds focus. Caveats
    /// (best-effort, see Activation.swift): menu key equivalents usually won't
    /// fire in a non-frontmost app, and Chromium/Electron apps can mishandle
    /// input while inactive.
    private func post(_ event: CGEvent?, pid: pid_t) {
        switch eventDestination(background: background, targetPid: pid) {
        case .session: event?.post(tap: .cghidEventTap)
        case .pid(let pid): event?.postToPid(pid)
        }
    }

    // MARK: - Actions

    public func click(_ input: ClickInput) throws -> ActionResult {
        try guardNotPaused()
        _ = try mouseButton(input.mouse_button) // validate early
        if let index = input.element_index {
            let app = try registry.resolve(input.app)
            let element = try capture.element(forIndex: index, appPid: app.processIdentifier)
            let window = try capture.focusedWindow(of: app)
            raiseUnlessBackground(app: app, window: window) // unobscured post-action screenshots
            let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
            guard err == .success else { throw mapAXError(err, action: "click[\(index)]") }
        } else if let x = input.x, let y = input.y {
            let (app, window, geometry) = try target(input.app, needsGeometry: true)
            raiseUnlessBackground(app: app, window: window)
            let point = globalPoint(fromScreenshotX: x, y: y, geometry: geometry!)
            let (button, down, up, _) = try mouseButton(input.mouse_button)
            let clicks = input.click_count ?? 1
            for i in 1...max(clicks, 1) {
                let downEvent = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: button)
                let upEvent = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: button)
                downEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                upEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                post(downEvent, pid: app.processIdentifier)
                post(upEvent, pid: app.processIdentifier)
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
        raiseUnlessBackground(app: app, window: window)
        // The chord parse yields ANSI key codes; remap character keys to the
        // ACTIVE keyboard layout (on e.g. Dvorak the ANSI "c" code types "j",
        // so Cmd+c would fire an unbound shortcut and silently no-op).
        let layoutChord = KeyChord(keyCode: layoutKeyCode(forAnsi: chord.keyCode), flags: chord.flags)
        // Post the chord as a physical typist would: modifiers held as their own
        // flagsChanged events around the main key (see keyEventSequence), which
        // is how real key equivalents are delivered to NSMenu. One shared source
        // keeps the whole sequence in a single event stream.
        let source = CGEventSource(stateID: .hidSystemState)
        for step in keyEventSequence(for: layoutChord) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: step.keyCode, keyDown: step.keyDown)
            if isModifierKeyCode(step.keyCode) {
                // Physical modifiers arrive as flagsChanged, never keyDown/keyUp;
                // menu-equivalent matching ignores modifier keyDowns.
                event?.type = .flagsChanged
            }
            event?.flags = step.flags
            post(event, pid: app.processIdentifier)
            usleep(5_000) // real chords have inter-key spacing; keeps order stable
        }
        postActionSleep()
        return ActionResult(done: true)
    }

    public func typeText(_ input: TypeTextInput) throws -> ActionResult {
        try guardNotPaused()
        let (app, window, _) = try target(input.app, needsGeometry: false)
        raiseUnlessBackground(app: app, window: window)
        // Unicode key events into current focus, ~20 UTF-16 units per event
        // (surrogate pairs are never split across events; see utf16Chunks).
        for chunk in utf16Chunks(input.text) {
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            post(down, pid: app.processIdentifier)
            post(up, pid: app.processIdentifier)
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
        raiseUnlessBackground(app: app, window: window)

        // Move the cursor over the element's VISIBLE center, then post pixel
        // scrolls of one visible-height/width per page. Scrollable content
        // elements report full-content-sized AX frames extending far past the
        // window, so the raw frame center can lie over a different window and
        // the wheel event would scroll that one instead; clamp to the window.
        guard let elementFrame = axFrame(of: element) else {
            throw SkyServiceError(code: .elementNotActionable, message: "scroll[\(input.element_index)]: element has no frame")
        }
        let frame = axFrame(of: window)
            .map { visibleScrollFrame(elementFrame: elementFrame, windowFrame: $0) } ?? elementFrame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left),
             pid: app.processIdentifier)
        usleep(50_000) // let the pointer move settle before the wheel events
        let total = Int32((vertical ? frame.height : frame.width) * sign * input.pages)
        let source = CGEventSource(stateID: .hidSystemState)
        for delta in scrollDeltas(total: total) {
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                wheel1: vertical ? delta : 0, wheel2: vertical ? 0 : delta, wheel3: 0)
            event?.location = center // route by the clamped point, immune to cursor races
            post(event, pid: app.processIdentifier)
            usleep(10_000)
        }
        postActionSleep()
        return ActionResult(done: true)
    }

    public func setValue(_ input: SetValueInput) throws -> ActionResult {
        try guardNotPaused()
        let app = try registry.resolve(input.app)
        let element = try capture.element(forIndex: input.element_index, appPid: app.processIdentifier)
        let window = try capture.focusedWindow(of: app)
        raiseUnlessBackground(app: app, window: window)
        let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, input.value as CFString)
        guard err == .success else { throw mapAXError(err, action: "set_value[\(input.element_index)]") }
        postActionSleep()
        return ActionResult(done: true)
    }

    public func drag(_ input: DragInput) throws -> ActionResult {
        try guardNotPaused()
        let (button, down, up, dragged) = try mouseButton(input.mouse_button)
        let (app, window, geometry) = try target(input.app, needsGeometry: true)
        raiseUnlessBackground(app: app, window: window)
        let from = globalPoint(fromScreenshotX: input.from_x, y: input.from_y, geometry: geometry!)
        let to = globalPoint(fromScreenshotX: input.to_x, y: input.to_y, geometry: geometry!)
        post(CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: from, mouseButton: button),
             pid: app.processIdentifier)
        let steps = 12
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let mid = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            post(CGEvent(mouseEventSource: nil, mouseType: dragged, mouseCursorPosition: mid, mouseButton: button),
                 pid: app.processIdentifier)
            usleep(15_000)
        }
        post(CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: to, mouseButton: button),
             pid: app.processIdentifier)
        postActionSleep()
        return ActionResult(done: true)
    }

    public func performSecondaryAction(_ input: PerformSecondaryActionInput) throws -> ActionResult {
        try guardNotPaused()
        let app = try registry.resolve(input.app)
        let element = try capture.element(forIndex: input.element_index, appPid: app.processIdentifier)
        let window = try capture.focusedWindow(of: app)
        raiseUnlessBackground(app: app, window: window)
        let err = AXUIElementPerformAction(element, input.action as CFString)
        guard err == .success else { throw mapAXError(err, action: "perform_secondary_action(\(input.action))") }
        postActionSleep()
        return ActionResult(done: true)
    }

    /// Milestone 2: locate the match in the element's value and set the
    /// selection range (or collapse to a cursor) via kAXSelectedTextRangeAttribute.
    public func selectText(_ input: SelectTextInput) throws -> ActionResult {
        try guardNotPaused()
        let app = try registry.resolve(input.app)
        let element = try capture.element(forIndex: input.element_index, appPid: app.processIdentifier)
        let window = try capture.focusedWindow(of: app)
        raiseUnlessBackground(app: app, window: window)
        guard let value: String = axAttribute(element, kAXValueAttribute) else {
            throw SkyServiceError(code: .elementNotActionable,
                                  message: "select_text[\(input.element_index)]: element has no text value")
        }
        var range = try resolveSelectionRange(in: value, text: input.text, prefix: input.prefix,
                                              suffix: input.suffix, selectionType: input.selection_type)
        guard let axRange = AXValueCreate(.cfRange, &range) else {
            throw SkyServiceError(code: .elementNotActionable, message: "select_text: cannot build CFRange")
        }
        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
        guard err == .success else { throw mapAXError(err, action: "select_text[\(input.element_index)]") }
        postActionSleep()
        return ActionResult(done: true)
    }
}
