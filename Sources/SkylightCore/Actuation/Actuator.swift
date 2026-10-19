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

/// The approval tier a click needs. A plain left click only presses what is
/// on screen; a right or middle click opens context menus (which offer Paste)
/// and a modifier click changes what a click means, so both need `full`.
public func requiredClickTier(mouseButton: String?, hasModifiers: Bool) -> ApprovalTier {
    (mouseButton ?? "left") == "left" && !hasModifiers ? .click : .full
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
    /// through this, so the allowlist cannot be bypassed. `need` is the tier
    /// the action requires and `action` names it in a refusal.
    private func resolveApproved(_ identifier: String, need: ApprovalTier, action: String) throws -> NSRunningApplication {
        let app = try registry.resolve(identifier)
        try approvals.check(name: app.localizedName, bundleID: app.bundleIdentifier, need: need, action: action)
        return app
    }

    /// The app for an action that named none: the app owning the UI under
    /// `point` (AX hit test). Approval-gated like an explicit target.
    ///
    /// When a point is given and the hit test cannot name an app, this is an
    /// error rather than "use the frontmost app". Those are different apps
    /// whenever it matters — a dialog or another app's floating panel over the
    /// one in front is exactly when the hit test fails — and clicking a
    /// coordinate in the wrong app is worse than refusing. Without a point
    /// (keyboard actions) the frontmost app IS the documented target.
    private func resolveImplicit(point: CGPoint?, need: ApprovalTier, action: String) throws -> NSRunningApplication {
        if let point {
            var element: AXUIElement?
            if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
               let element {
                var pid: pid_t = 0
                if AXUIElementGetPid(element, &pid) == .success, let app = NSRunningApplication(processIdentifier: pid) {
                    try approvals.check(name: app.localizedName, bundleID: app.bundleIdentifier, need: need, action: action)
                    return app
                }
            }
            throw SkyServiceError(
                code: .appNotFound,
                message: "no app could be identified at (\(Int(point.x)), \(Int(point.y))) — pass `app` "
                    + "explicitly. (Falling back to the frontmost app here would act on a different "
                    + "app than the one under the point.)")
        }
        guard let front = NSWorkspace.shared.frontmostApplication else {
            throw SkyServiceError(code: .appNotFound, message: "no frontmost app to target; pass app explicitly")
        }
        try approvals.check(name: front.localizedName, bundleID: front.bundleIdentifier, need: need, action: action)
        return front
    }

    /// Explicit target when given, implicit (hit test / frontmost) otherwise.
    private func resolveApproved(_ identifier: String?, near point: CGPoint? = nil,
                                 need: ApprovalTier, action: String) throws -> NSRunningApplication {
        if let identifier { return try resolveApproved(identifier, need: need, action: action) }
        return try resolveImplicit(point: point, need: need, action: action)
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
    private func displayTarget(_ appIdentifier: String?, at point: CGPoint, need: ApprovalTier, action: String) throws
        -> (app: NSRunningApplication, window: AXUIElement?) {
        let app = try resolveApproved(appIdentifier, near: point, need: need, action: action)
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
    private func target(_ appIdentifier: String, needsGeometry: Bool, need: ApprovalTier, action: String) throws
        -> (app: NSRunningApplication, window: AXUIElement, geometry: CaptureGeometry?) {
        let app = try resolveApproved(appIdentifier, need: need, action: action)
        var geometry: CaptureGeometry?
        if needsGeometry {
            guard let g = capture.latestGeometry(forPid: app.processIdentifier) else {
                throw SkyServiceError(code: .invalidParams,
                                      message: "no prior capture for '\(appIdentifier)' — coordinates are screenshot pixels; call get_app_state first")
            }
            geometry = g
        }
        if needsGeometry, let windowID = capture.latestWindowID(forPid: app.processIdentifier) {
            // The coordinates describe THAT window. If it is gone, they mean
            // nothing: falling through to whatever is focused now would land
            // the click at the same pixels in a different window.
            guard let listing = try? capture.windowListings(of: app).first(where: { $0.info.window_id == windowID })
            else {
                throw SkyServiceError(
                    code: .staleElementIndex,
                    message: "the window those coordinates came from (window_id \(windowID)) is gone — "
                        + "call get_app_state again and use pixels of the new capture")
            }
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
        guard let windowID = capture.latestWindowID(forPid: app.processIdentifier) else {
            // No capture has named a window for this app yet (or the private
            // window-id bridge is unavailable): the focused window is the only
            // thing it could mean.
            return try capture.focusedWindow(of: app)
        }
        guard let listing = try? capture.windowListings(of: app).first(where: { $0.info.window_id == windowID })
        else {
            throw SkyServiceError(
                code: .staleElementIndex,
                message: "the window the last capture used (window_id \(windowID)) is gone — "
                    + "call get_app_state again")
        }
        return listing.element
    }

    /// The window a pointer action on `element` must aim at: the element's own
    /// window. An index can come from a different window than the latest
    /// capture — `find`/`wait_for` with `window_id`, or a `return_state`
    /// capture that walked a dialog — and aiming at the captured window would
    /// clamp the point into it and stamp the event with its id, landing the
    /// action in the wrong window. Falls back to the captured window only for
    /// an element that reports no window.
    private func window(containing element: AXUIElement, of app: NSRunningApplication) throws -> AXUIElement {
        if let own: AXUIElement = axAttribute(element, kAXWindowAttribute) { return own }
        return try capturedWindow(of: app)
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
    /// Returns the flip to undo once the action's events have been delivered,
    /// or nil when nothing was flipped (foreground mode, an AX-only action, or
    /// the target was already frontmost). Callers `defer` the restore.
    @discardableResult
    private func prepareTarget(app: NSRunningApplication, window: AXUIElement?,
                               background: Bool, action: ActuatorAction) -> FocusFlip? {
        guard shouldActivate(background: background) else {
            if needsAppActive(action: action), let window {
                return focusWithoutRaise(app: app, window: window)
            }
            return nil
        }
        guard let window else {
            // No window to raise (menu-bar app, or a process whose dialog the
            // AX hit test found but which reports no focused window): plain
            // activation still routes session-tap events to it.
            app.activate()
            let deadline = Date().addingTimeInterval(2.0)
            while !app.isActive && Date() < deadline { usleep(20_000) }
            usleep(80_000)
            return nil
        }
        activateAndRaise(app: app, window: window)
        return nil
    }

    /// Puts the user's frontmost app back the way it was.
    ///
    /// Deferred by every action that flips focus, so it runs after the events
    /// are posted AND after `postActionSleep` — the target needs to still
    /// believe it is active while it processes them.
    private func restore(_ flip: FocusFlip?) {
        guard let flip else { return }
        restoreFocus(flip)
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
    private func postHover(app: NSRunningApplication, point: CGPoint, background: Bool, settleMs: Int) {
        let approach = CGPoint(x: point.x - 1, y: point.y - 1)
        for (p, delta) in [(approach, 0.0), (point, 1.0)] {
            let event = makeMouse(.mouseMoved, at: p, clickCount: 0, window: nil, background: background)
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

    /// Refuses a background coordinate action aimed at a window we cannot name.
    ///
    /// A background mouse event has to carry the target window id, and without
    /// one `makeMouse` falls back to a plain CGEvent — which is precisely the
    /// "delivered and then ignored" case this whole path exists to end, except
    /// it would still report done:true. Reachable through the display_id path,
    /// where the hit-tested app may have no focused window at all (menu-bar
    /// apps, bare dialogs).
    private func requireNamedWindow(_ window: MouseWindow?, background: Bool, action: String) throws {
        guard background, window == nil else { return }
        throw SkyServiceError(
            code: .backgroundUnavailable,
            message: "\(action): the target window could not be identified (no window id or frame), "
                + "so a background \(action) cannot name where it is going and would be ignored. "
                + "Retry with background: false, or act by element_index.")
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
    /// `flags` are the modifier keys held for the event (a Cmd-click); they
    /// ride on the mouse event itself, which is what an app reads them from.
    private func makeMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left,
                           clickCount: Int = 1, flags: CGEventFlags = [], window: MouseWindow?,
                           background: Bool) -> CGEvent? {
        if background, BackgroundMouse.isButtonEvent(type), let window,
           let event = BackgroundMouse.event(type: type, global: point, windowID: window.id,
                                             windowFrame: window.frame, button: button,
                                             clickCount: clickCount) {
            if !flags.isEmpty { event.flags = flags }
            return event
        }
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        // Click state belongs to a press, not to a move: a mouseMoved carrying
        // clickState 1 claims a button is down.
        if BackgroundMouse.isButtonEvent(type) {
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        }
        if !flags.isEmpty { event?.flags = flags }
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
    private func keyboardTarget(_ appIdentifier: String?, action: String) throws -> (app: NSRunningApplication, window: AXUIElement?) {
        if let appIdentifier {
            let (app, window, _) = try target(appIdentifier, needsGeometry: false, need: .full, action: action)
            return (app, window)
        }
        let app = try resolveImplicit(point: nil, need: .full, action: action)
        return (app, try? capture.focusedWindow(of: app))
    }

    /// The scroll area `element` scrolls: itself or its nearest AXScrollArea
    /// ancestor (a list or text view inside one is the usual target).
    private func scrollArea(containing element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let e = current else { return nil }
            if (axAttribute(e, kAXRoleAttribute) as String?) == (kAXScrollAreaRole as String) { return e }
            current = axAttribute(e, kAXParentAttribute)
        }
        return nil
    }

    /// Scrolls by moving the scroll area's AX scroll bar, which needs no focus
    /// and no events. One page is the visible length, as with the wheel path.
    /// Returns false when there is no settable scroll bar, or the write did not
    /// move it (an app that ignores it) — the caller then refuses instead of
    /// reporting a scroll that never happened.
    private func axScroll(element: AXUIElement, vertical: Bool, towardEnd: Bool, pages: Double) -> Bool {
        guard let area = scrollArea(containing: element),
              let bar: AXUIElement = axAttribute(area, vertical ? kAXVerticalScrollBarAttribute
                                                                : kAXHorizontalScrollBarAttribute),
              let current = (axAttribute(bar, kAXValueAttribute) as NSNumber?)?.doubleValue,
              let areaFrame = axFrame(of: area)
        else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        // The document view is the scroll area's content child; its frame is
        // the full scrollable size.
        let contents: [AXUIElement] = (axAttribute(area, kAXContentsAttribute) as CFArray?)
            .map { ($0 as [AnyObject]).filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
                .map { unsafeDowncast($0, to: AXUIElement.self) } } ?? []
        guard let contentFrame = contents.compactMap({ axFrame(of: $0) }).max(by: {
            vertical ? $0.height < $1.height : $0.width < $1.width
        }) else { return false }
        let visible = vertical ? areaFrame.height : areaFrame.width
        let content = vertical ? contentFrame.height : contentFrame.width
        guard let target = scrollBarTarget(current: current, visible: visible, content: content,
                                           pages: pages, towardEnd: towardEnd) else { return false }
        // Already at the end in that direction: nothing to move, and that is
        // the same outcome a wheel would have.
        if target == current { return true }
        guard AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, target as CFNumber) == .success
        else { return false }
        usleep(50_000)
        let after = (axAttribute(bar, kAXValueAttribute) as NSNumber?)?.doubleValue
        return after.map { abs($0 - current) > 1e-6 } ?? false
    }

    // MARK: - Actions

    public func click(_ input: ClickInput) throws -> ActionResult {
        try guardNotPaused()
        // Function scope, so the restore runs after the events are posted —
        // not at the end of whichever branch resolved the target.
        var flip: FocusFlip?
        defer { restore(flip) }
        let background = effectiveBackground(input.background)
        let (button, down, up, _) = try mouseButton(input.mouse_button) // validate early
        let flags = try parseModifiers(input.modifiers)
        let need = requiredClickTier(mouseButton: input.mouse_button, hasModifiers: !flags.isEmpty)
        let app: NSRunningApplication
        let point: CGPoint
        let windowElement: AXUIElement?
        if let index = input.element_index {
            guard let appIdentifier = input.app else {
                throw SkyServiceError(code: .invalidParams, message: "click by element_index needs app")
            }
            if flags.isEmpty {
                let app = try resolveApproved(appIdentifier, need: need, action: "click")
                let element = try capture.element(forIndex: index, appPid: app.processIdentifier)
                let window = try capture.focusedWindow(of: app)
                flip = prepareTarget(app: app, window: window, background: background, action: .elementClick)
                let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
                guard err == .success else { throw mapAXError(err, action: "click[\(index)]") }
                postActionSleep()
                return ActionResult(done: true)
            }
            // An AX press has no modifier state, so a modifier click on an
            // element is a pointer click at its visible center.
            try requireBackgroundPointerReaches(background, action: "click")
            app = try resolveApproved(appIdentifier, need: need, action: "click")
            let element = try capture.element(forIndex: index, appPid: app.processIdentifier)
            let window = try window(containing: element, of: app)
            point = try pointerPoint(element: element, window: window, action: "click[\(index)]")
            windowElement = window
            flip = prepareTarget(app: app, window: window, background: background, action: .coordinateClick)
        } else if let x = input.x, let y = input.y {
            // Before prepareTarget: the refusal is pure and cheap, and running
            // the focus flip first would deactivate the user's frontmost app
            // for an action that is about to be refused.
            try requireBackgroundPointerReaches(background, action: "click")
            if let displayID = input.display_id {
                point = try displayPoint(x: x, y: y, displayID: displayID)
                let resolved = try displayTarget(input.app, at: point, need: need, action: "click")
                app = resolved.app
                windowElement = resolved.window
                flip = prepareTarget(app: app, window: resolved.window, background: background, action: .coordinateClick)
            } else {
                guard let appIdentifier = input.app else {
                    throw SkyServiceError(code: .invalidParams,
                                          message: "click by window coordinates needs app (or pass display_id for screen coordinates)")
                }
                let (resolvedApp, window, geometry) = try target(appIdentifier, needsGeometry: true,
                                                                 need: need, action: "click")
                app = resolvedApp
                windowElement = window
                flip = prepareTarget(app: app, window: window, background: background, action: .coordinateClick)
                point = globalPoint(fromScreenshotX: x, y: y, geometry: geometry!)
            }
        } else {
            throw SkyServiceError(code: .invalidParams, message: "click needs element_index or x+y")
        }
        // Which window the press names. A background click is ignored
        // without it (see BackgroundMouse).
        let window = mouseWindow(windowElement)
        try requireNamedWindow(window, background: background, action: "click")
        primeUserActivationIfNeeded(app: app, background: background)
        // After the primer (which parks the pointer at (-1,-1)), never
        // before: the primer would otherwise undo the hover.
        if input.hover ?? true {
            postHover(app: app, point: point, background: background,
                      settleMs: preClickHoverSettleMs)
        }
        let clicks = input.click_count ?? 1
        for i in 1...max(clicks, 1) {
            let downEvent = makeMouse(down, at: point, button: button, clickCount: i, flags: flags,
                                      window: window, background: background)
            let upEvent = makeMouse(up, at: point, button: button, clickCount: i, flags: flags,
                                    window: window, background: background)
            post(downEvent, pid: app.processIdentifier, background: background)
            // A real click has a press duration; a down and up sharing a
            // timestamp is not one.
            usleep(40_000)
            post(upEvent, pid: app.processIdentifier, background: background)
            if i < max(clicks, 1) { usleep(60_000) }
        }
        postActionSleep()
        return ActionResult(done: true)
    }

    /// Moves the pointer onto an element or point and holds it there, so
    /// hover-only UI renders before the next capture. Clicks nothing.
    public func hover(_ input: HoverInput) throws -> ActionResult {
        try guardNotPaused()
        // Function scope, so the restore runs after the events are posted —
        // not at the end of whichever branch resolved the target.
        var flip: FocusFlip?
        defer { restore(flip) }
        let background = effectiveBackground(input.background)
        let app: NSRunningApplication
        let point: CGPoint
        if let index = input.element_index {
            guard let appIdentifier = input.app else {
                throw SkyServiceError(code: .invalidParams, message: "hover by element_index needs app")
            }
            app = try resolveApproved(appIdentifier, need: .click, action: "hover")
            let element = try capture.element(forIndex: index, appPid: app.processIdentifier)
            let window = try window(containing: element, of: app)
            point = try pointerPoint(element: element, window: window, action: "hover[\(index)]")
            flip = prepareTarget(app: app, window: window, background: background, action: .hover)
        } else if let x = input.x, let y = input.y {
            if let displayID = input.display_id {
                point = try displayPoint(x: x, y: y, displayID: displayID)
                let resolved = try displayTarget(input.app, at: point, need: .click, action: "hover")
                app = resolved.app
                flip = prepareTarget(app: app, window: resolved.window, background: background, action: .hover)
            } else {
                guard let appIdentifier = input.app else {
                    throw SkyServiceError(code: .invalidParams,
                                          message: "hover by window coordinates needs app (or pass display_id for screen coordinates)")
                }
                let (resolvedApp, window, geometry) = try target(appIdentifier, needsGeometry: true,
                                                                 need: .click, action: "hover")
                app = resolvedApp
                flip = prepareTarget(app: app, window: window, background: background, action: .hover)
                point = globalPoint(fromScreenshotX: x, y: y, geometry: geometry!)
            }
        } else {
            throw SkyServiceError(code: .invalidParams, message: "hover needs element_index or x+y")
        }
        // Hold the pointer there: hover UI often fades in, and the caller's
        // next get_app_state must see the settled state, not the transition.
        postHover(app: app, point: point, background: background,
                  settleMs: hoverSettleMs(input.settle_ms))
        return ActionResult(done: true)
    }

    public func pressKey(_ input: PressKeyInput) throws -> ActionResult {
        try guardNotPaused()
        // Function scope, so the restore runs after the events are posted —
        // not at the end of whichever branch resolved the target.
        var flip: FocusFlip?
        defer { restore(flip) }
        let background = effectiveBackground(input.background)
        let chord = try parseKeyChord(input.keys)
        let (app, window) = try keyboardTarget(input.app, action: "press_key")
        flip = prepareTarget(app: app, window: window, background: background, action: .pressKey)
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
        // Function scope, so the restore runs after the events are posted —
        // not at the end of whichever branch resolved the target.
        var flip: FocusFlip?
        defer { restore(flip) }
        let background = effectiveBackground(input.background)
        let app: NSRunningApplication
        let window: AXUIElement?
        var focusTarget: AXUIElement?
        if let index = input.element_index {
            guard let appIdentifier = input.app else {
                throw SkyServiceError(code: .invalidParams, message: "type_text by element_index needs app")
            }
            app = try resolveApproved(appIdentifier, need: .full, action: "type_text")
            focusTarget = try capture.element(forIndex: index, appPid: app.processIdentifier)
            window = try? capture.focusedWindow(of: app)
        } else {
            (app, window) = try keyboardTarget(input.app, action: "type_text")
        }
        flip = prepareTarget(app: app, window: window, background: background, action: .typeText)
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
        // Function scope, so the restore runs after the events are posted —
        // not at the end of whichever branch resolved the target.
        var flip: FocusFlip?
        defer { restore(flip) }
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
        let app = try resolveApproved(input.app, need: .click, action: "scroll")
        let element = try capture.element(forIndex: input.element_index, appPid: app.processIdentifier)
        // Scroll wheels have no NSEvent constructor, so the window-stamped
        // construction that rescued background clicks cannot be built for them.
        // Verified live on macOS 27 in both engines: a wheel posted per-pid
        // scrolls neither a Chromium page nor an AppKit scroll view, while the
        // same scroll in the foreground works. What does work without focus is
        // moving the scroll area's AX scroll bar, which most AppKit scroll
        // views expose; only when there is none is background scroll refused.
        if background {
            guard axScroll(element: element, vertical: vertical, towardEnd: sign < 0, pages: input.pages) else {
                throw SkyServiceError(
                    code: .backgroundUnavailable,
                    message: "scroll: no scroll bar to move through accessibility here, and a scroll wheel "
                        + "cannot be delivered in the background — wheel events cannot carry the window "
                        + "stamp that makes a background click land (verified against Chromium on macOS 27). "
                        + "Retry with background: false, which activates the app first.")
            }
            postActionSleep()
            return ActionResult(done: true)
        }
        let window = try capture.focusedWindow(of: app)
        flip = prepareTarget(app: app, window: window, background: background, action: .scroll)

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
        // Function scope, so the restore runs after the events are posted —
        // not at the end of whichever branch resolved the target.
        var flip: FocusFlip?
        defer { restore(flip) }
        let background = effectiveBackground(input.background)
        let app = try resolveApproved(input.app, need: .full, action: "set_value")
        let element = try capture.element(forIndex: input.element_index, appPid: app.processIdentifier)
        let window = try capture.focusedWindow(of: app)
        flip = prepareTarget(app: app, window: window, background: background, action: .setValue)
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
        // Function scope, so the restore runs after the events are posted —
        // not at the end of whichever branch resolved the target.
        var flip: FocusFlip?
        defer { restore(flip) }
        let background = effectiveBackground(input.background)
        let (button, down, up, dragged) = try mouseButton(input.mouse_button)
        let flags = try parseModifiers(input.modifiers)
        // Each end is an element or a point; validate both before touching anything.
        let fromPoint = input.from_x.flatMap { x in input.from_y.map { CGPoint(x: x, y: $0) } }
        let toPoint = input.to_x.flatMap { x in input.to_y.map { CGPoint(x: x, y: $0) } }
        guard input.from_element_index != nil || fromPoint != nil,
              input.to_element_index != nil || toPoint != nil else {
            throw SkyServiceError(code: .invalidParams,
                                  message: "drag needs a start (from_element_index or from_x+from_y) and an end "
                                      + "(to_element_index or to_x+to_y)")
        }
        let usesElements = input.from_element_index != nil || input.to_element_index != nil
        // Before prepareTarget, as in click.
        try requireBackgroundPointerReaches(background, action: "drag")
        let app: NSRunningApplication
        let from: CGPoint
        let to: CGPoint
        let windowElement: AXUIElement?
        if let displayID = input.display_id, !usesElements {
            from = try displayPoint(x: fromPoint!.x, y: fromPoint!.y, displayID: displayID)
            to = try displayPoint(x: toPoint!.x, y: toPoint!.y, displayID: displayID)
            let resolved = try displayTarget(input.app, at: from, need: .full, action: "drag")
            app = resolved.app
            windowElement = resolved.window
        } else {
            guard let appIdentifier = input.app else {
                throw SkyServiceError(code: .invalidParams,
                                      message: usesElements
                                          ? "drag by element_index needs app"
                                          : "drag by window coordinates needs app (or pass display_id for screen coordinates)")
            }
            // Window coordinates need the latest capture's geometry; element
            // ends need only the window that capture used.
            let needsGeometry = input.display_id == nil && (fromPoint != nil && input.from_element_index == nil
                                                            || toPoint != nil && input.to_element_index == nil)
            let (resolvedApp, targetWindow, geometry) = try target(appIdentifier, needsGeometry: needsGeometry,
                                                                   need: .full, action: "drag")
            app = resolvedApp
            let fromElement = try input.from_element_index.map { try capture.element(forIndex: $0, appPid: app.processIdentifier) }
            let toElement = try input.to_element_index.map { try capture.element(forIndex: $0, appPid: app.processIdentifier) }
            let elementWindows = try [fromElement, toElement].compactMap { $0 }.map { try self.window(containing: $0, of: app) }
            // One drag is one window: both ends, and the geometry a coordinate
            // end is read against, must agree on which.
            let window = needsGeometry ? targetWindow : elementWindows[0]
            guard elementWindows.allSatisfy({ CFEqual($0, window) }) else {
                throw SkyServiceError(code: .invalidParams,
                                      message: "drag: the two ends are in different windows"
                                          + (needsGeometry ? " (a coordinate end refers to the last get_app_state window)" : "")
                                          + " — a drag cannot cross windows")
            }
            windowElement = window
            func end(element: AXUIElement?, index: Int?, point: CGPoint?, label: String) throws -> CGPoint {
                if let element, let index {
                    return try pointerPoint(element: element, window: window, action: "drag \(label)[\(index)]")
                }
                if let displayID = input.display_id {
                    return try displayPoint(x: point!.x, y: point!.y, displayID: displayID)
                }
                return globalPoint(fromScreenshotX: point!.x, y: point!.y, geometry: geometry!)
            }
            from = try end(element: fromElement, index: input.from_element_index, point: fromPoint, label: "from")
            to = try end(element: toElement, index: input.to_element_index, point: toPoint, label: "to")
        }
        flip = prepareTarget(app: app, window: windowElement, background: background, action: .drag)
        let window = mouseWindow(windowElement)
        try requireNamedWindow(window, background: background, action: "drag")
        post(makeMouse(down, at: from, button: button, flags: flags, window: window, background: background),
             pid: app.processIdentifier, background: background)
        let steps = 12
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let mid = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            post(makeMouse(dragged, at: mid, button: button, flags: flags, window: window, background: background),
                 pid: app.processIdentifier, background: background)
            usleep(15_000)
        }
        post(makeMouse(up, at: to, button: button, flags: flags, window: window, background: background),
             pid: app.processIdentifier, background: background)
        postActionSleep()
        return ActionResult(done: true)
    }

    public func performSecondaryAction(_ input: PerformSecondaryActionInput) throws -> ActionResult {
        try guardNotPaused()
        // Function scope, so the restore runs after the events are posted —
        // not at the end of whichever branch resolved the target.
        var flip: FocusFlip?
        defer { restore(flip) }
        let background = effectiveBackground(input.background)
        let app = try resolveApproved(input.app, need: .full, action: "perform_secondary_action")
        let element = try capture.element(forIndex: input.element_index, appPid: app.processIdentifier)
        let window = try capture.focusedWindow(of: app)
        flip = prepareTarget(app: app, window: window, background: background, action: .performSecondaryAction)
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
        let app = try resolveApproved(input.app, need: .click, action: "bring_to_active_space")
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
        // Function scope, so the restore runs after the events are posted —
        // not at the end of whichever branch resolved the target.
        var flip: FocusFlip?
        defer { restore(flip) }
        let background = effectiveBackground(input.background)
        let app = try resolveApproved(input.app, need: .click, action: "select_text")
        let element = try capture.element(forIndex: input.element_index, appPid: app.processIdentifier)
        let window = try capture.focusedWindow(of: app)
        flip = prepareTarget(app: app, window: window, background: background, action: .selectText)
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

    // MARK: - Menus

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        (axAttribute(element, kAXChildrenAttribute) as CFArray?)
            .map { ($0 as [AnyObject]).filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
                .map { unsafeDowncast($0, to: AXUIElement.self) } } ?? []
    }

    /// The items one level below `item`: a menu bar item or submenu item holds
    /// one AXMenu, whose children are the items.
    private func menuItems(under item: AXUIElement) -> [AXUIElement] {
        childElements(of: item)
            .filter { (axAttribute($0, kAXRoleAttribute) as String?) == (kAXMenuRole as String) }
            .flatMap { childElements(of: $0) }
    }

    /// Presses a menu item by its title path from the menu bar, e.g.
    /// ["File", "Export As…"]. An AX press on the item, so the menu never
    /// opens on screen and the app need not be frontmost.
    public func menuSelect(_ input: MenuSelectInput) throws -> ActionResult {
        try guardNotPaused()
        var flip: FocusFlip?
        defer { restore(flip) }
        guard input.path.count >= 2 else {
            throw SkyServiceError(code: .invalidParams,
                                  message: "menu_select path needs a menu and an item, e.g. [\"File\", \"Save\"]")
        }
        let background = effectiveBackground(input.background)
        let app = try resolveApproved(input.app, need: .full, action: "menu_select")
        // Before reading the menus: their enabled state is computed against
        // the key window, which an inactive app does not have.
        flip = prepareTarget(app: app, window: try? capture.focusedWindow(of: app), background: background,
                             action: .menuSelect)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar: AXUIElement = axAttribute(appElement, kAXMenuBarAttribute) else {
            throw SkyServiceError(code: .elementNotActionable, message: "menu_select: '\(input.app)' has no menu bar")
        }
        var item: AXUIElement?
        for (depth, wanted) in input.path.enumerated() {
            let candidates = item.map { menuItems(under: $0) } ?? childElements(of: menuBar)
            let titles = candidates.map { (axAttribute($0, kAXTitleAttribute) as String?) ?? "" }
            guard let i = titles.firstIndex(where: { normalizedMenuTitle($0) == normalizedMenuTitle(wanted) }) else {
                let place = depth == 0 ? "the menu bar" : input.path[..<depth].joined(separator: " > ")
                let available = titles.filter { !$0.isEmpty }.joined(separator: ", ")
                throw SkyServiceError(code: .elementNotActionable,
                                      message: "menu_select: no '\(wanted)' in \(place). Available: \(available)")
            }
            item = candidates[i]
        }
        let target = item!
        if let enabled = axAttribute(target, kAXEnabledAttribute) as NSNumber?, !enabled.boolValue {
            throw SkyServiceError(code: .elementNotActionable,
                                  message: "menu_select: '\(input.path.joined(separator: " > "))' is disabled right now")
        }
        let err = AXUIElementPerformAction(target, kAXPressAction as CFString)
        guard err == .success else {
            throw mapAXError(err, action: "menu_select(\(input.path.joined(separator: " > ")))")
        }
        postActionSleep()
        return ActionResult(done: true)
    }

    // MARK: - Launching

    /// Launches an app (or brings a running one up) and optionally opens a URL
    /// or file with it. Waits until the app has finished launching, so the
    /// next get_app_state finds it.
    public func openApp(_ input: OpenAppInput) throws -> OpenAppResult {
        try guardNotPaused()
        let background = effectiveBackground(input.background)
        let resolved = try? registry.resolve(input.app)
        guard let bundleURL = resolved?.bundleURL ?? registry.locateApplication(input.app) else {
            throw SkyServiceError(code: .appNotFound,
                                  message: "no installed app matches '\(input.app)' — pass its name as in /Applications, "
                                      + "its bundle id, or the path of the .app")
        }
        let bundle = Bundle(url: bundleURL)
        // Running-ness by the bundle actually being opened: `resolve` misses
        // an app named by path, or by a name other than its display name.
        let running = resolved ?? bundle?.bundleIdentifier.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        }
        let name = running?.localizedName
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        // Approval first, so a refused call reveals nothing about the url
        // (not even whether a file exists). Launching is a read-level act, but
        // handing an app a file or URL is not: Terminal runs a .command file
        // it is given.
        try approvals.check(name: name, bundleID: running?.bundleIdentifier ?? bundle?.bundleIdentifier,
                            need: input.url == nil ? .read : .full,
                            action: input.url == nil ? "open_app" : "open_app with a url")
        var urls: [URL] = []
        if let raw = input.url {
            if raw.hasPrefix("/") || raw.hasPrefix("~") {
                let path = (raw as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: path) else {
                    throw SkyServiceError(code: .invalidParams, message: "open_app: no file at \(path)")
                }
                urls = [URL(fileURLWithPath: path)]
            } else if let url = URL(string: raw), url.scheme != nil {
                urls = [url]
            } else {
                throw SkyServiceError(code: .invalidParams,
                                      message: "open_app: url must be an absolute file path or a URL with a scheme")
            }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = !background
        var outcome: Result<NSRunningApplication, Error>?
        let done = DispatchSemaphore(value: 0)
        let completion: (NSRunningApplication?, Error?) -> Void = { app, error in
            if let app { outcome = .success(app) } else {
                outcome = .failure(error ?? SkyServiceError(code: .captureFailed, message: "launch returned no app"))
            }
            done.signal()
        }
        if urls.isEmpty {
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config, completionHandler: completion)
        } else {
            NSWorkspace.shared.open(urls, withApplicationAt: bundleURL, configuration: config, completionHandler: completion)
        }
        // 15s + 5s below stays under the IPC server's 30s request timeout.
        guard done.wait(timeout: .now() + 15) == .success, let outcome else {
            throw SkyServiceError(code: .timeout, message: "open_app: '\(name)' did not finish launching within 15s")
        }
        let app: NSRunningApplication
        switch outcome {
        case .success(let a): app = a
        case .failure(let error):
            throw SkyServiceError(code: .elementNotActionable, message: "open_app: could not open '\(name)': \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(5)
        while !app.isFinishedLaunching, Date() < deadline { usleep(50_000) }
        return OpenAppResult(app: registry.info(for: app), launched: running == nil)
    }
}
