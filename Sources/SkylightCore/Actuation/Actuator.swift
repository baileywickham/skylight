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

/// How long `hover` holds the pointer in place before returning: 250 ms by
/// default, never more than 5s — a hover occupies the app's actuation slot,
/// and nothing renders a hover state that slowly.
public func hoverSettleMs(_ requested: Int?) -> Int {
    min(max(requested ?? 250, 0), 5_000)
}

/// Pause between a coordinate click's pointer move and its press. A control
/// that a web UI renders on hover needs a layout frame before it is under the
/// pointer to be hit; verified live — at 0ms the press lands on the row behind
/// the button that the same move just created.
public let preClickHoverSettleMs = 150

/// Upper bound on `press_key`'s repeat. High enough for "delete this line",
/// low enough that a typo cannot hold a key down for minutes.
public let maxKeyRepeat = 200

/// How many times `press_key` sends its chord: 1 by default, never more than
/// `maxKeyRepeat`, never less than 1 (0 or a negative repeat is a caller
/// mistake, and silently doing nothing would look like a delivery failure).
public func keyRepeatCount(_ requested: Int?) -> Int {
    min(max(requested ?? 1, 1), maxKeyRepeat)
}

/// Whether a `set_value` write took, given the value before the write and the
/// value read back after it.
///
/// AX returns success for a set the app then discards — a controlled React
/// input re-renders from its own state and the old text is back a frame later
/// (verified live in Chromium: the setter returns .success either way). So the
/// write is judged by what the element says afterwards, not by the return code:
///
/// - reads back as what we asked: applied.
/// - reads back as something else: the app took the write and normalized it
///   (trimmed, reformatted, clamped a slider). Still applied — refusing here
///   would fail every field with an input mask.
/// - exposes no readable value at all (a secure field, a custom element): not
///   observable, so not something to fail on. Unverifiable is not the same as
///   wrong, and inventing a failure here would break writes that do land.
/// - unchanged, and not what we asked: the app threw the write away.
public func valueWriteLanded(before: String?, after: String?, expected: String) -> Bool {
    if after == expected { return true }
    guard let after else { return true }
    return after != before
}


/// Performs the API's actions against live apps. NOT thread-safe (it shares
/// AXCapture's per-app index map): all calls must stay on the daemon's global
/// serial actuation queue, where the router already runs handlers.
public final class Actuator {
    private let registry: AppRegistry
    private let capture: AXCapture
    private let postActionSleepMs: Int
    private let pauseFile: URL
    /// Daemon-wide default (see `BackgroundSettings`). Each action may
    /// override per request via its optional `background` field. A closure so
    /// the daemon re-resolves it per request and `skylight background` applies
    /// without a restart.
    private let defaultBackground: () -> Bool
    private let approvals: Approvals
    /// Latest `screenshot` geometry per display, for click/drag with display_id.
    private let displayGeometry: DisplayGeometryStore
    /// How long to wait for an AX focus or value write to show up in the tree.
    /// Web content applies both asynchronously — measured at ~300ms for a
    /// Chromium text field, so this leaves headroom without stalling a call.
    private let focusSettleSeconds: TimeInterval = 1.0

    public init(registry: AppRegistry, capture: AXCapture,
                postActionSleepMs: Int = 100, pauseFile: URL = SkylightPaths.pauseFile,
                background: @escaping @autoclosure () -> Bool = false, approvals: Approvals = Approvals(),
                displayGeometry: DisplayGeometryStore = DisplayGeometryStore()) {
        self.registry = registry
        self.capture = capture
        self.postActionSleepMs = postActionSleepMs
        self.pauseFile = pauseFile
        self.defaultBackground = background
        self.approvals = approvals
        self.displayGeometry = displayGeometry
    }

    /// Per-request override wins; absent falls back to the daemon default.
    public func effectiveBackground(_ override: Bool?) -> Bool {
        override ?? defaultBackground()
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

    /// Resolve + approval-gate in one step; every action targets apps only
    /// through this, so the allowlist cannot be bypassed.
    private func resolveApproved(_ identifier: String) throws -> NSRunningApplication {
        let app = try registry.resolve(identifier)
        try approvals.check(name: app.localizedName, bundleID: app.bundleIdentifier)
        return app
    }

    /// The app for an action that named none: the app owning the UI under
    /// `point` (AX hit test), else the frontmost app. Approval-gated like an
    /// explicit target. Hit-testing matters because the frontmost app is not
    /// always what is under the pointer — a system dialog or another app's
    /// floating panel can sit over it.
    private func resolveImplicit(point: CGPoint?) throws -> NSRunningApplication {
        if let point {
            var element: AXUIElement?
            if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
               let element {
                var pid: pid_t = 0
                if AXUIElementGetPid(element, &pid) == .success, let app = NSRunningApplication(processIdentifier: pid) {
                    try approvals.check(name: app.localizedName, bundleID: app.bundleIdentifier)
                    return app
                }
            }
        }
        guard let front = NSWorkspace.shared.frontmostApplication else {
            throw SkyServiceError(code: .appNotFound, message: "no frontmost app to target; pass app explicitly")
        }
        try approvals.check(name: front.localizedName, bundleID: front.bundleIdentifier)
        return front
    }

    /// Explicit target when given, implicit (hit test / frontmost) otherwise.
    private func resolveApproved(_ identifier: String?, near point: CGPoint? = nil) throws -> NSRunningApplication {
        if let identifier { return try resolveApproved(identifier) }
        return try resolveImplicit(point: point)
    }

    /// Display-coordinate actions: converts pixels of the latest `screenshot`
    /// of `displayID` to a global point. Fails fast when there was no such
    /// screenshot, exactly like window coordinates without a prior capture.
    private func displayPoint(x: Double, y: Double, displayID: Int) throws -> CGPoint {
        guard let geometry = displayGeometry.latest(forDisplay: CGDirectDisplayID(displayID)) else {
            throw SkyServiceError(code: .invalidParams,
                                  message: "no prior screenshot of display \(displayID) — coordinates are screenshot pixels; call screenshot first")
        }
        return displayGlobalPoint(x: x, y: y, geometry: geometry)
    }

    /// Like `target(_:needsGeometry:)` for a display-space action: the app is
    /// hit-tested at `point` unless named, and the window is the app's focused
    /// one if it has any (menu-bar apps and bare dialogs may not).
    private func displayTarget(_ appIdentifier: String?, at point: CGPoint) throws
        -> (app: NSRunningApplication, window: AXUIElement?) {
        let app = try resolveApproved(appIdentifier, near: point)
        return (app, try? capture.focusedWindow(of: app))
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
    ///
    /// When `needsGeometry` is true, the window we raise MUST be the same
    /// window the geometry came from — get_app_state can target a specific
    /// window_id, and a stale `focusedWindow(of:)` lookup here would raise a
    /// different window than the one coordinates were computed against,
    /// landing the click/drag in the wrong place. So we resolve the window
    /// that produced the committed geometry (via its window_id) and fall
    /// back to the live focused window only if that id is nil or no longer
    /// resolves (e.g. the window closed).
    private func target(_ appIdentifier: String, needsGeometry: Bool) throws
        -> (app: NSRunningApplication, window: AXUIElement, geometry: CaptureGeometry?) {
        let app = try resolveApproved(appIdentifier)
        var geometry: CaptureGeometry?
        if needsGeometry {
            guard let g = capture.latestGeometry(forPid: app.processIdentifier) else {
                throw SkyServiceError(code: .invalidParams,
                                      message: "no prior capture for '\(appIdentifier)' — coordinates are screenshot pixels; call get_app_state first")
            }
            geometry = g
        }
        if needsGeometry, let windowID = capture.latestWindowID(forPid: app.processIdentifier),
           let listing = try? capture.windowListings(of: app).first(where: { $0.info.window_id == windowID }) {
            return (app, listing.element, geometry)
        }
        let window = try capture.focusedWindow(of: app)
        return (app, window, geometry)
    }

    /// The window an element action should treat as the target: the one the
    /// latest capture used, not whatever is focused now. It matters for
    /// pointer actions — a hover into a window that is not the app's key
    /// window is dropped, and after the focus flip the wrong window would
    /// become key.
    private func capturedWindow(of app: NSRunningApplication) throws -> AXUIElement {
        if let windowID = capture.latestWindowID(forPid: app.processIdentifier),
           let listing = try? capture.windowListings(of: app).first(where: { $0.info.window_id == windowID }) {
            return listing.element
        }
        return try capture.focusedWindow(of: app)
    }

    /// Readies the target for an action.
    ///
    /// Foreground: bring it frontmost so session events land in it
    /// and post-action screenshots are unobscured.
    ///
    /// Background: never raise. Actions that deliver synthetic events also need
    /// the app to be AppKit-active for key equivalents to resolve, so those get
    /// `focusWithoutRaise`; pure AX-element actions skip it, since they work
    /// regardless of focus and flipping the user's frontmost app to inactive is
    /// a real (if brief) disturbance not worth paying for nothing.
    private func prepareTarget(app: NSRunningApplication, window: AXUIElement?,
                               background: Bool, action: ActuatorAction) {
        guard shouldActivate(background: background) else {
            if deliversSyntheticEvents(action: action), let window {
                focusWithoutRaise(app: app, window: window)
            }
            return
        }
        guard let window else {
            // No window to raise (menu-bar app, or a process whose dialog the
            // AX hit test found but which reports no focused window): plain
            // activation still routes session-tap events to it.
            app.activate()
            let deadline = Date().addingTimeInterval(2.0)
            while !app.isActive && Date() < deadline { usleep(20_000) }
            usleep(80_000)
            return
        }
        activateAndRaise(app: app, window: window)
    }

    /// Chromium drops synthetic clicks into a backgrounded window unless they
    /// follow a user gesture; a throwaway pair outside every window supplies
    /// one. No-op for non-Chromium apps and in foreground mode.
    private func primeUserActivationIfNeeded(app: NSRunningApplication, background: Bool) {
        guard background, needsUserActivationPrimer(bundleID: app.bundleIdentifier) else { return }
        let pid = app.processIdentifier
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                mouseCursorPosition: userActivationPrimerPoint, mouseButton: .left)
            post(event, pid: pid, background: true)
        }
        usleep(5_000)
    }

    /// Parks the pointer at `point` so the app renders its hover state there.
    ///
    /// Two moves, one pixel apart, with the delta fields set: an app tracks
    /// hover by mouse-move deltas, and a single event at a position it already
    /// believes the pointer occupies can be coalesced away. In background mode
    /// these go per-pid, so the app sees a pointer the user's real cursor never
    /// followed — which is the whole point: hover-only affordances render
    /// without disturbing anyone.
    private func postHover(app: NSRunningApplication, point: CGPoint, background: Bool, settleMs: Int,
                           window: MouseWindow? = nil) {
        let approach = CGPoint(x: point.x - 1, y: point.y - 1)
        for (p, delta) in [(approach, 0.0), (point, 1.0)] {
            let event = makeMouse(.mouseMoved, at: p, clickCount: 0, window: window, background: background)
            // Deltas last: they are what an app tracks hover by, and the
            // NSEvent construction does not carry them.
            event?.setDoubleValueField(.mouseEventDeltaX, value: delta)
            event?.setDoubleValueField(.mouseEventDeltaY, value: delta)
            post(event, pid: app.processIdentifier, background: background)
            usleep(15_000)
        }
        if settleMs > 0 { usleep(UInt32(settleMs) * 1000) }
    }

    /// The point a pointer action aims at for an element: the center of the
    /// part of its frame that is actually on-window, like `scroll` — an AX
    /// frame can extend past the window (scrollable content) and its raw
    /// center can land over a different window entirely.
    private func pointerFrame(element: AXUIElement, window: AXUIElement, action: String) throws -> CGRect {
        guard let elementFrame = axFrame(of: element) else {
            throw SkyServiceError(code: .elementNotActionable, message: "\(action): element has no frame")
        }
        return axFrame(of: window)
            .map { visibleScrollFrame(elementFrame: elementFrame, windowFrame: $0) } ?? elementFrame
    }

    private func pointerPoint(element: AXUIElement, window: AXUIElement, action: String) throws -> CGPoint {
        let frame = try pointerFrame(element: element, window: window, action: action)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Refuses a background coordinate action this machine cannot deliver,
    /// instead of posting an event that is swallowed and reporting success —
    /// the silent no-op this whole path exists to end.
    private func requireBackgroundPointerReaches(_ background: Bool, action: String) throws {
        guard background, !backgroundPointerReaches() else { return }
        throw SkyServiceError(
            code: .backgroundUnavailable,
            message: "\(action): this machine cannot deliver a background coordinate \(action) — "
                + "the private window-stamp or focus-without-raise support is missing "
                + "(see `skylight doctor`). Click by element_index instead — an AX press needs no "
                + "focus — or retry with background: false.")
    }

    /// What a background mouse event needs to name its target window. nil when
    /// the window cannot be identified (no window, or the private window-id
    /// bridge is unavailable), which drops event construction back to a plain
    /// CGEvent.
    struct MouseWindow {
        let id: CGWindowID
        let frame: CGRect
    }

    private func mouseWindow(_ window: AXUIElement?) -> MouseWindow? {
        guard let window, let id = axWindowID(of: window), let frame = axFrame(of: window) else { return nil }
        return MouseWindow(id: id, frame: frame)
    }

    /// Builds a mouse event for `point`.
    ///
    /// In background mode, against a window we can name, a BUTTON event gets
    /// the NSEvent-derived, window-stamped construction that a backgrounded app
    /// will actually act on (see `BackgroundMouse` — a plain CGEvent posted
    /// per-pid is delivered and then ignored). Foreground, or when the window
    /// is unknown, it is the plain CGEvent that has always been posted: in the
    /// foreground the event goes through the session tap and the window server
    /// resolves the window itself.
    ///
    /// Mouse MOVES deliberately stay plain, even in the background: they were
    /// never the broken case, and the NSEvent construction actively breaks them
    /// — verified live, an NSEvent-built move does not register as a hover in
    /// Chromium, which takes `hover` (and every hover-only control it reaches)
    /// with it.
    private func makeMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left,
                           clickCount: Int = 1, window: MouseWindow?, background: Bool) -> CGEvent? {
        if background, BackgroundMouse.isButtonEvent(type), let window,
           let event = BackgroundMouse.event(type: type, global: point, windowID: window.id,
                                             windowFrame: window.frame, button: button,
                                             clickCount: clickCount) {
            return event
        }
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        return event
    }

    /// Delivers a synthetic event. Foreground: session HID tap (frontmost
    /// app). Background: CGEventPostToPid into `pid`'s event queue, so the
    /// event reaches the target even while another app holds focus (menu
    /// equivalents fire because `prepareTarget` ran focusWithoutRaise first).
    private func post(_ event: CGEvent?, pid: pid_t, background: Bool) {
        switch eventDestination(background: background, targetPid: pid) {
        case .session: event?.post(tap: .cghidEventTap)
        case .pid(let pid): event?.postToPid(pid)
        }
    }

    /// Makes `element` the app's focused element, so the keystrokes that follow
    /// land in it and nowhere else.
    ///
    /// The setter's return code proves nothing: Chromium reports success and
    /// applies the focus a frame later, and an element that refuses focus
    /// entirely reports success too. So poll the app's focused element until it
    /// is the one we asked for, and fail if it never becomes that.
    private func focusElement(_ element: AXUIElement, app: NSRunningApplication, action: String) throws {
        let err = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard err == .success else { throw mapAXError(err, action: "\(action): focus") }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let deadline = Date().addingTimeInterval(focusSettleSeconds)
        repeat {
            if let focused: AXUIElement = axAttribute(appElement, kAXFocusedUIElementAttribute as String),
               CFEqual(focused, element) {
                return
            }
            usleep(25_000)
        } while Date() < deadline
        throw SkyServiceError(
            code: .elementNotActionable,
            message: "\(action): element never took focus — click it first, or omit element_index to type into whatever is focused")
    }

    /// The element's AX value as the tree renders it, so a read-back compares
    /// like with like (a checkbox's value is a number, a field's is a string).
    private func valueString(of element: AXUIElement) -> String? {
        let raw: CFTypeRef? = axAttribute(element, kAXValueAttribute as String)
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    /// Keyboard actions: the named app's raised window, or — with no app —
    /// the frontmost app and whatever focused window it has.
    private func keyboardTarget(_ appIdentifier: String?) throws -> (app: NSRunningApplication, window: AXUIElement?) {
        if let appIdentifier {
            let (app, window, _) = try target(appIdentifier, needsGeometry: false)
            return (app, window)
        }
        let app = try resolveImplicit(point: nil)
        return (app, try? capture.focusedWindow(of: app))
    }

    // MARK: - Actions

    public func click(_ input: ClickInput) throws -> ActionResult {
        try guardNotPaused()
        let background = effectiveBackground(input.background)
        _ = try mouseButton(input.mouse_button) // validate early
        if let index = input.element_index {
            guard let appIdentifier = input.app else {
                throw SkyServiceError(code: .invalidParams, message: "click by element_index needs app")
            }
            let app = try resolveApproved(appIdentifier)
            let element = try capture.element(forIndex: index, appPid: app.processIdentifier)
            let window = try capture.focusedWindow(of: app)
            prepareTarget(app: app, window: window, background: background, action: .elementClick)
            let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
            guard err == .success else { throw mapAXError(err, action: "click[\(index)]") }
        } else if let x = input.x, let y = input.y {
            let app: NSRunningApplication
            let point: CGPoint
            let windowElement: AXUIElement?
            if let displayID = input.display_id {
                point = try displayPoint(x: x, y: y, displayID: displayID)
                let resolved = try displayTarget(input.app, at: point)
                app = resolved.app
                windowElement = resolved.window
                prepareTarget(app: app, window: resolved.window, background: background, action: .coordinateClick)
            } else {
                guard let appIdentifier = input.app else {
                    throw SkyServiceError(code: .invalidParams,
                                          message: "click by window coordinates needs app (or pass display_id for screen coordinates)")
                }
                let (resolvedApp, window, geometry) = try target(appIdentifier, needsGeometry: true)
                app = resolvedApp
                windowElement = window
                prepareTarget(app: app, window: window, background: background, action: .coordinateClick)
                point = globalPoint(fromScreenshotX: x, y: y, geometry: geometry!)
            }
            try requireBackgroundPointerReaches(background, action: "click")
            // Which window the press names. A background click is ignored
            // without it (see BackgroundMouse).
            let window = mouseWindow(windowElement)
            primeUserActivationIfNeeded(app: app, background: background)
            // After the primer (which parks the pointer at (-1,-1)), never
            // before: the primer would otherwise undo the hover.
            if input.hover ?? true {
                postHover(app: app, point: point, background: background,
                          settleMs: preClickHoverSettleMs, window: window)
            }
            let (button, down, up, _) = try mouseButton(input.mouse_button)
            let clicks = input.click_count ?? 1
            for i in 1...max(clicks, 1) {
                let downEvent = makeMouse(down, at: point, button: button, clickCount: i,
                                          window: window, background: background)
                let upEvent = makeMouse(up, at: point, button: button, clickCount: i,
                                        window: window, background: background)
                post(downEvent, pid: app.processIdentifier, background: background)
                // A real click has a press duration; a down and up sharing a
                // timestamp is not one.
                usleep(40_000)
                post(upEvent, pid: app.processIdentifier, background: background)
                if i < max(clicks, 1) { usleep(60_000) }
            }
        } else {
            throw SkyServiceError(code: .invalidParams, message: "click needs element_index or x+y")
        }
        postActionSleep()
        return ActionResult(done: true)
    }

    /// Moves the pointer onto an element or point and holds it there, so
    /// hover-only UI renders before the next capture. Clicks nothing.
    public func hover(_ input: HoverInput) throws -> ActionResult {
        try guardNotPaused()
        let background = effectiveBackground(input.background)
        let app: NSRunningApplication
        let point: CGPoint
        var hoverWindow: MouseWindow?
        if let index = input.element_index {
            guard let appIdentifier = input.app else {
                throw SkyServiceError(code: .invalidParams, message: "hover by element_index needs app")
            }
            app = try resolveApproved(appIdentifier)
            let element = try capture.element(forIndex: index, appPid: app.processIdentifier)
            let window = try capturedWindow(of: app)
            point = try pointerPoint(element: element, window: window, action: "hover[\(index)]")
            hoverWindow = mouseWindow(window)
            prepareTarget(app: app, window: window, background: background, action: .hover)
        } else if let x = input.x, let y = input.y {
            if let displayID = input.display_id {
                point = try displayPoint(x: x, y: y, displayID: displayID)
                let resolved = try displayTarget(input.app, at: point)
                app = resolved.app
                hoverWindow = mouseWindow(resolved.window)
                prepareTarget(app: app, window: resolved.window, background: background, action: .hover)
            } else {
                guard let appIdentifier = input.app else {
                    throw SkyServiceError(code: .invalidParams,
                                          message: "hover by window coordinates needs app (or pass display_id for screen coordinates)")
                }
                let (resolvedApp, window, geometry) = try target(appIdentifier, needsGeometry: true)
                app = resolvedApp
                hoverWindow = mouseWindow(window)
                prepareTarget(app: app, window: window, background: background, action: .hover)
                point = globalPoint(fromScreenshotX: x, y: y, geometry: geometry!)
            }
        } else {
            throw SkyServiceError(code: .invalidParams, message: "hover needs element_index or x+y")
        }
        // Hold the pointer there: hover UI often fades in, and the caller's
        // next get_app_state must see the settled state, not the transition.
        postHover(app: app, point: point, background: background,
                  settleMs: hoverSettleMs(input.settle_ms), window: hoverWindow)
        return ActionResult(done: true)
    }

    public func pressKey(_ input: PressKeyInput) throws -> ActionResult {
        try guardNotPaused()
        let background = effectiveBackground(input.background)
        let chord = try parseKeyChord(input.keys)
        let (app, window) = try keyboardTarget(input.app)
        prepareTarget(app: app, window: window, background: background, action: .pressKey)
        // The chord parse yields ANSI key codes; remap character keys to the
        // ACTIVE keyboard layout (on e.g. Dvorak the ANSI "c" code types "j",
        // so Cmd+c would fire an unbound shortcut and silently no-op).
        let layoutChord = KeyChord(keyCode: layoutKeyCode(forAnsi: chord.keyCode), flags: chord.flags)
        // Post the chord as a physical typist would: modifiers held as their own
        // flagsChanged events around the main key (see keyEventSequence), which
        // is how real key equivalents are delivered to NSMenu. One shared source
        // keeps the whole sequence in a single event stream.
        let source = CGEventSource(stateID: .hidSystemState)
        let repeats = keyRepeatCount(input.`repeat`)
        for _ in 0..<repeats {
            for step in keyEventSequence(for: layoutChord) {
                let event = CGEvent(keyboardEventSource: source, virtualKey: step.keyCode, keyDown: step.keyDown)
                if isModifierKeyCode(step.keyCode) {
                    // Physical modifiers arrive as flagsChanged, never keyDown/keyUp;
                    // menu-equivalent matching ignores modifier keyDowns.
                    event?.type = .flagsChanged
                }
                event?.flags = step.flags
                post(event, pid: app.processIdentifier, background: background)
                usleep(5_000) // real chords have inter-key spacing; keeps order stable
            }
            // Gap between repeats, so the app sees separate presses rather than
            // one smeared chord — a text field that coalesces them would delete
            // one character for twenty BackSpaces.
            if repeats > 1 { usleep(15_000) }
        }
        postActionSleep()
        return ActionResult(done: true)
    }

    public func typeText(_ input: TypeTextInput) throws -> ActionResult {
        try guardNotPaused()
        let background = effectiveBackground(input.background)
        let app: NSRunningApplication
        let window: AXUIElement?
        var focusTarget: AXUIElement?
        if let index = input.element_index {
            guard let appIdentifier = input.app else {
                throw SkyServiceError(code: .invalidParams, message: "type_text by element_index needs app")
            }
            app = try resolveApproved(appIdentifier)
            focusTarget = try capture.element(forIndex: index, appPid: app.processIdentifier)
            window = try? capture.focusedWindow(of: app)
        } else {
            (app, window) = try keyboardTarget(input.app)
        }
        prepareTarget(app: app, window: window, background: background, action: .typeText)
        // After prepareTarget: in foreground mode the activation moves focus
        // around, so focusing the element first would be undone by the raise.
        if let focusTarget, let index = input.element_index {
            try focusElement(focusTarget, app: app, action: "type_text[\(index)]")
        }
        // Unicode key events into current focus, ~20 UTF-16 units per event
        // (surrogate pairs are never split across events; see utf16Chunks).
        for chunk in utf16Chunks(input.text) {
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            post(down, pid: app.processIdentifier, background: background)
            post(up, pid: app.processIdentifier, background: background)
            usleep(5_000) // keep event order stable for fast typists
        }
        postActionSleep()
        return ActionResult(done: true)
    }

    public func scroll(_ input: ScrollInput) throws -> ActionResult {
        try guardNotPaused()
        let background = effectiveBackground(input.background)
        let vertical: Bool
        let sign: Double
        switch input.direction {
        case "up": vertical = true; sign = 1
        case "down": vertical = true; sign = -1
        case "left": vertical = false; sign = 1
        case "right": vertical = false; sign = -1
        default: throw SkyServiceError(code: .invalidParams, message: "direction must be up|down|left|right")
        }
        let app = try resolveApproved(input.app)
        // Scroll wheels have no NSEvent constructor, so the window-stamped
        // construction that rescued background clicks cannot be built for them.
        // Verified live on macOS 27 in both engines: a wheel posted per-pid
        // scrolls neither a Chromium page nor an AppKit scroll view, while the
        // same scroll in the foreground works.
        if background {
            throw SkyServiceError(
                code: .backgroundUnavailable,
                message: "scroll: a scroll wheel cannot be delivered in the background — wheel "
                    + "events cannot carry the window stamp that makes a background click land "
                    + "(verified against Chromium on macOS 27). Retry with background: false, "
                    + "which activates the app first.")
        }
        let element = try capture.element(forIndex: input.element_index, appPid: app.processIdentifier)
        let window = try capture.focusedWindow(of: app)
        prepareTarget(app: app, window: window, background: background, action: .scroll)

        // Move the cursor over the element's VISIBLE center, then post pixel
        // scrolls of one visible-height/width per page. Scrollable content
        // elements report full-content-sized AX frames extending far past the
        // window, so the raw frame center can lie over a different window and
        // the wheel event would scroll that one instead; clamp to the window.
        let frame = try pointerFrame(element: element, window: window, action: "scroll[\(input.element_index)]")
        let center = CGPoint(x: frame.midX, y: frame.midY)
        post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left),
             pid: app.processIdentifier, background: background)
        usleep(50_000) // let the pointer move settle before the wheel events
        let total = Int32((vertical ? frame.height : frame.width) * sign * input.pages)
        let source = CGEventSource(stateID: .hidSystemState)
        for delta in scrollDeltas(total: total) {
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                wheel1: vertical ? delta : 0, wheel2: vertical ? 0 : delta, wheel3: 0)
            event?.location = center // route by the clamped point, immune to cursor races
            post(event, pid: app.processIdentifier, background: background)
            usleep(10_000)
        }
        postActionSleep()
        return ActionResult(done: true)
    }

    public func setValue(_ input: SetValueInput) throws -> ActionResult {
        try guardNotPaused()
        let background = effectiveBackground(input.background)
        let app = try resolveApproved(input.app)
        let element = try capture.element(forIndex: input.element_index, appPid: app.processIdentifier)
        let window = try capture.focusedWindow(of: app)
        prepareTarget(app: app, window: window, background: background, action: .setValue)
        let before = valueString(of: element)
        let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, input.value as CFString)
        guard err == .success else { throw mapAXError(err, action: "set_value[\(input.element_index)]") }
        postActionSleep()
        // Read it back: AX success does not mean the app kept the write.
        let deadline = Date().addingTimeInterval(focusSettleSeconds)
        var after = valueString(of: element)
        while !valueWriteLanded(before: before, after: after, expected: input.value), Date() < deadline {
            usleep(25_000)
            after = valueString(of: element)
        }
        guard valueWriteLanded(before: before, after: after, expected: input.value) else {
            throw SkyServiceError(
                code: .elementNotActionable,
                message: "set_value[\(input.element_index)]: the app accepted the write and kept its old value "
                    + "\"\(after ?? "")\" — it is driving this field from its own state (a controlled web input). "
                    + "Click or focus the field and use type_text instead.")
        }
        return ActionResult(done: true)
    }

    public func drag(_ input: DragInput) throws -> ActionResult {
        try guardNotPaused()
        let background = effectiveBackground(input.background)
        let (button, down, up, dragged) = try mouseButton(input.mouse_button)
        let app: NSRunningApplication
        let from: CGPoint
        let to: CGPoint
        let windowElement: AXUIElement?
        if let displayID = input.display_id {
            from = try displayPoint(x: input.from_x, y: input.from_y, displayID: displayID)
            to = try displayPoint(x: input.to_x, y: input.to_y, displayID: displayID)
            let resolved = try displayTarget(input.app, at: from)
            app = resolved.app
            windowElement = resolved.window
            prepareTarget(app: app, window: resolved.window, background: background, action: .drag)
        } else {
            guard let appIdentifier = input.app else {
                throw SkyServiceError(code: .invalidParams,
                                      message: "drag by window coordinates needs app (or pass display_id for screen coordinates)")
            }
            let (resolvedApp, window, geometry) = try target(appIdentifier, needsGeometry: true)
            app = resolvedApp
            windowElement = window
            prepareTarget(app: app, window: window, background: background, action: .drag)
            from = globalPoint(fromScreenshotX: input.from_x, y: input.from_y, geometry: geometry!)
            to = globalPoint(fromScreenshotX: input.to_x, y: input.to_y, geometry: geometry!)
        }
        try requireBackgroundPointerReaches(background, action: "drag")
        let window = mouseWindow(windowElement)
        post(makeMouse(down, at: from, button: button, window: window, background: background),
             pid: app.processIdentifier, background: background)
        let steps = 12
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let mid = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            post(makeMouse(dragged, at: mid, button: button, window: window, background: background),
                 pid: app.processIdentifier, background: background)
            usleep(15_000)
        }
        post(makeMouse(up, at: to, button: button, window: window, background: background),
             pid: app.processIdentifier, background: background)
        postActionSleep()
        return ActionResult(done: true)
    }

    public func performSecondaryAction(_ input: PerformSecondaryActionInput) throws -> ActionResult {
        try guardNotPaused()
        let background = effectiveBackground(input.background)
        let app = try resolveApproved(input.app)
        let element = try capture.element(forIndex: input.element_index, appPid: app.processIdentifier)
        let window = try capture.focusedWindow(of: app)
        prepareTarget(app: app, window: window, background: background, action: .performSecondaryAction)
        let err = AXUIElementPerformAction(element, input.action as CFString)
        guard err == .success else { throw mapAXError(err, action: "perform_secondary_action(\(input.action))") }
        postActionSleep()
        return ActionResult(done: true)
    }

    /// Moves a window onto the Space the user is looking at without switching
    /// Spaces — the low-disturbance way to make an off-Space window
    /// capturable and clickable. No-op when it is already there.
    public func bringToActiveSpace(_ input: BringToActiveSpaceInput) throws -> BringToActiveSpaceResult {
        try guardNotPaused()
        guard SkyLightBridge.canManageSpaces else {
            throw SkyServiceError(code: .notImplemented,
                                  message: "Spaces bridge unavailable on this macOS (capabilities.skylight.space_management=false)")
        }
        let app = try resolveApproved(input.app)
        let listings = try capture.windowListings(of: app)
        let listing: AXCapture.WindowListing
        if let wanted = input.window_id {
            guard let match = listings.first(where: { $0.info.window_id == wanted }) else {
                throw SkyServiceError(code: .invalidParams, message: "window_id \(wanted) is not a window of '\(input.app)'")
            }
            listing = match
        } else {
            guard let focused = listings.first(where: { $0.info.is_focused }) ?? listings.first else {
                throw SkyServiceError(code: .noFocusedWindow, message: "'\(input.app)' has no windows")
            }
            listing = focused
        }
        guard let windowID = listing.info.window_id else {
            throw SkyServiceError(code: .notImplemented, message: "window id bridge unavailable; cannot address the window")
        }
        let wid = CGWindowID(windowID)
        if SkyLightBridge.isOnActiveSpace(windowID: wid) == true {
            return BringToActiveSpaceResult(window_id: windowID, on_active_space: true, moved: false)
        }
        guard let active = SkyLightBridge.activeSpace() else {
            throw SkyServiceError(code: .captureFailed, message: "cannot determine the active Space")
        }
        if let type = SkyLightBridge.spaceType(active), type == 4 {
            throw SkyServiceError(code: .elementNotActionable,
                                  message: "the active Space is a fullscreen app; windows cannot be moved into it")
        }
        let moved = SkyLightBridge.moveWindow(wid, toSpace: active)
        postActionSleep()
        return BringToActiveSpaceResult(window_id: windowID, on_active_space: moved, moved: moved)
    }

    /// Milestone 2: locate the match in the element's value and set the
    /// selection range (or collapse to a cursor) via kAXSelectedTextRangeAttribute.
    public func selectText(_ input: SelectTextInput) throws -> ActionResult {
        try guardNotPaused()
        let background = effectiveBackground(input.background)
        let app = try resolveApproved(input.app)
        let element = try capture.element(forIndex: input.element_index, appPid: app.processIdentifier)
        let window = try capture.focusedWindow(of: app)
        prepareTarget(app: app, window: window, background: background, action: .selectText)
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
