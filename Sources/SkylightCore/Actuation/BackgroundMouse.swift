import CoreGraphics
import Darwin
import Foundation

/// The point in `windowFrame`'s own coordinates, **origin top-left**, for a
/// global CoreGraphics point.
///
/// This is what `CGEventSetWindowLocation` takes. AppKit's
/// `NSEvent.locationInWindow` is bottom-left — the window server does that
/// conversion itself, so flipping here flips it twice and mirrors every click
/// about the window's horizontal midline. That shipped once (v0.3.7): a click
/// aimed at `clientY≈81` arrived at 626 in an 828pt-tall viewport, and it looked
/// like "background clicks do not work in AppKit", because a click aimed at
/// TextEdit's first line landed below its last one.
public func windowLocalPoint(global: CGPoint, windowFrame: CGRect) -> CGPoint {
    CGPoint(x: global.x - windowFrame.minX, y: global.y - windowFrame.minY)
}

/// Builds mouse events that a **background** app will actually act on.
///
/// A CGEvent synthesized from scratch and posted with `CGEventPostToPid` is
/// delivered to the process and then ignored: nothing in it says which window
/// the click belongs to, so it reaches `-[NSApplication sendEvent:]` with
/// window number 0 and no view ever runs. Keystrokes are unaffected, which is
/// what makes the failure so confusing — the call still reports success.
/// Apple documents `CGEventPostToPid` only as a way to re-route events captured
/// from a tap (`CGEvent.h`: "by tapping events at the
/// `kCGAnnotatedSessionEventTap` location and then posting the events to
/// another desired process"), so a synthesized one landing was never promised.
///
/// Two stamps fix it, and only these two — the rest was cargo cult, dropped
/// after measuring on both Chromium and AppKit:
///
///   1. **`kCGMouseEventWindowNumber`** (field 51) = the target `CGWindowID`,
///      so the event resolves to a window. This is the one thing that building
///      the event through `NSEvent.mouseEvent` used to contribute — which is
///      why it is no longer built that way, keeping AppKit off the parallel
///      actuation queues.
///   2. **`CGEventSetWindowLocation`** with the window-local point. Without it
///      the event arrives at the right window with an unusable location — an
///      instrumented AppKit target logged `loc=(-1, y)` — and hits nothing.
///
/// Fields 91/92 (`kCGMouseEventWindowUnderMousePointer` and its handler twin)
/// are NOT required: removed on both engines, the click still lands.
///
/// The target must also be in a state to act on it: either the app is active —
/// which background actuation arranges without raising anything, via
/// `focusWithoutRaise` — or the event carries the Command modifier, macOS's
/// click-through gesture for an inactive window. Command is deliberately not
/// used: the app would see a Cmd-click, which means "open in a new tab" to a
/// browser and "extend the selection" to half of AppKit.
///
/// Mouse MOVES stay plain, unstamped CGEvents: the stamp is not what they were
/// missing, and stamping them breaks `hover` outright (an NSEvent-built move
/// stops registering as a hover in Chromium). What a move DOES need is the
/// target app believing it is active — a per-pid move produces `:hover` only
/// then — which is why `hover` takes the focus-without-raise flip; see
/// `deliversSyntheticEvents`.
///
/// Scroll wheels cannot be stamped this way (verified dead in both engines), so
/// `scroll` is refused in background mode.
///
/// **Drag caveat:** a background `mouseDragged` reports `buttons == 0` to the
/// page (a foreground one reports 1). Chromium derives that from
/// `-[NSEvent pressedMouseButtons]`, the real HID button state, which per-pid
/// posting never sets, and no CGEvent field substitutes for it. Text selection
/// and AppKit drags are unaffected — verified — but JavaScript that gates on
/// `e.buttons & 1` during mousemove (sliders, canvas painting, most drag
/// libraries) reads a background drag as a hover. Use `background: false`
/// there.
///
/// Like every other private entry point here (see `SkyLightBridge`), the symbol
/// is dlsym-probed: when it is missing, `event(...)` returns nil and the caller
/// posts the plain CGEvent it would have posted before.
public enum BackgroundMouse {
    private typealias SetWindowLocationFunc = @convention(c) (CGEvent, CGPoint) -> Void

    private static let setWindowLocationFn: SetWindowLocationFunc? =
        dlopen(nil, RTLD_NOW)
            .flatMap { dlsym($0, "CGEventSetWindowLocation") }
            .map { unsafeBitCast($0, to: SetWindowLocationFunc.self) }

    /// True when a background mouse event can be built at all. Reported through
    /// `capabilities` so a macOS release that drops the symbol is visible as a
    /// capability going false rather than as clicks that quietly stop working.
    public static var isAvailable: Bool { setWindowLocationFn != nil }

    /// `kCGMouseEventWindowNumber`: the window an event belongs to. Absent from
    /// the public `CGEventField` enum, so it is spelled by raw value.
    private static let windowNumberField = CGEventField(rawValue: 51)!

    /// Whether this event type carries a pressed button, i.e. whether it needs
    /// this treatment at all.
    public static func isButtonEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    /// A mouse event aimed at `windowID`, or nil when this cannot be built —
    /// the symbol is missing, the window is unknown, or the event carries no
    /// button. The caller then falls back to a plain CGEvent.
    public static func event(type: CGEventType, global: CGPoint, windowID: CGWindowID,
                             windowFrame: CGRect, button: CGMouseButton,
                             clickCount: Int) -> CGEvent? {
        guard let setWindowLocation = setWindowLocationFn,
              isButtonEvent(type), windowID != 0,
              let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: global, mouseButton: button)
        else { return nil }
        event.setIntegerValueField(windowNumberField, value: Int64(windowID))
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        // Global location for the window server, window-local for the view.
        event.location = global
        setWindowLocation(event, windowLocalPoint(global: global, windowFrame: windowFrame))
        return event
    }
}
