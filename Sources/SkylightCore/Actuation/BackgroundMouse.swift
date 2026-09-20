import AppKit
import CoreGraphics
import Darwin
import Foundation

/// The window-local point (AppKit coordinates, origin bottom-left of the
/// window) for a global CoreGraphics point (origin top-left of the display).
///
/// This is what `NSEvent.locationInWindow` reports, and a background mouse
/// event has to carry it explicitly — see `BackgroundMouse`.
public func windowLocalPoint(global: CGPoint, windowFrame: CGRect) -> CGPoint {
    CGPoint(x: global.x - windowFrame.minX,
            y: windowFrame.height - (global.y - windowFrame.minY))
}

/// Builds mouse events that a **background** app will actually act on.
///
/// A CGEvent synthesized from scratch and posted with `CGEventPostToPid` is
/// delivered to the process and then ignored: nothing in it says which window
/// the click belongs to, so AppKit resolves no view and the event dies
/// silently. Keystrokes and mouse MOVES are unaffected, which is what makes the
/// failure so confusing — `hover` works, the click that follows does nothing,
/// and the call still reports success. Measured on macOS 27.0 (26A428) against
/// Chromium and AppKit alike; Apple documents `CGEventPostToPid` as a way to
/// re-route events you captured from a tap, and never promised a synthesized
/// one would land, so this is unlikely to come back.
///
/// Three things together make it land. Each was removed in turn against a live
/// page counting DOM mouse events, and the click stopped registering every
/// time:
///
///   1. **Build it as an `NSEvent`** carrying the target's `windowNumber`, then
///      take its `cgEvent`. AppKit fills in a dozen fields a real click has and
///      a hand-built CGEvent does not; a CGEvent with the stamps below but
///      without this does not land.
///   2. **Stamp fields 91/92** (`kCGMouseEventWindowUnderMousePointer` and
///      `…ThatCanHandleThisEvent`) with the target `CGWindowID`.
///   3. **Stamp the window-local point** via the private
///      `CGEventSetWindowLocation`. `NSEvent.locationInWindow` comes from this,
///      not from the event's global `.location`.
///
/// The target must also believe it is active, which background actuation
/// already arranges with `focusWithoutRaise` — verified live: with that in
/// place the click lands in a background window while the user's frontmost app
/// and cursor never move. (Adding the Command modifier is the other way to get
/// click-through to an inactive window, and is deliberately NOT used here: the
/// app would see a Cmd-click, which means "open in a new tab" to a browser and
/// "extend the selection" to half of AppKit.)
///
/// Scope, measured rather than assumed: this lands in the Chromium family
/// (Chrome, Electron shells) and NOT in AppKit — TextEdit ignores the stamped
/// event, the plain one, and the Command-modifier click-through variant alike,
/// while the identical foreground click lands instantly. `Activation`'s
/// `backgroundPointerReaches` is the gate that turns the rest into an honest
/// error. Scroll wheels have no `NSEvent` constructor and stay undeliverable in
/// the background in both engines; `scroll` needs `background: false`.
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

    /// Event numbers are per-event-stream sequence tags on real clicks; AppKit
    /// only needs them distinct and increasing.
    private static let eventNumber = AtomicCounter()

    /// Serializes event construction. `ActuationScheduler` runs actions for
    /// DIFFERENT apps in parallel, so two threads can reach this at once, and
    /// what happens below is AppKit object creation off the main thread. It is
    /// a few microseconds of work with no I/O, so one lock costs nothing and
    /// removes the question.
    private static let buildLock = NSLock()

    /// The NSEvent type for a CG mouse event type, or nil for an event kind
    /// NSEvent cannot construct (scroll wheels).
    public static func nsType(for type: CGEventType) -> NSEvent.EventType? {
        switch type {
        case .leftMouseDown: return .leftMouseDown
        case .leftMouseUp: return .leftMouseUp
        case .rightMouseDown: return .rightMouseDown
        case .rightMouseUp: return .rightMouseUp
        case .otherMouseDown: return .otherMouseDown
        case .otherMouseUp: return .otherMouseUp
        case .mouseMoved: return .mouseMoved
        case .leftMouseDragged: return .leftMouseDragged
        case .rightMouseDragged: return .rightMouseDragged
        case .otherMouseDragged: return .otherMouseDragged
        default: return nil
        }
    }

    /// Whether this event type carries a pressed button, i.e. whether it needs
    /// this treatment at all. Moves land per-pid as plain CGEvents and must
    /// STAY plain: an NSEvent-built move stops registering as a hover in
    /// Chromium (verified live — it takes every hover-only control with it).
    public static func isButtonEvent(_ type: CGEventType) -> Bool {
        nsType(for: type).map { $0 != .mouseMoved } ?? false
    }

    /// A mouse event aimed at `windowID`, or nil when this cannot be built —
    /// the symbol is missing, the window is unknown, or NSEvent has no such
    /// event type. The caller falls back to a plain CGEvent.
    public static func event(type: CGEventType, global: CGPoint, windowID: CGWindowID,
                             windowFrame: CGRect, button: CGMouseButton,
                             clickCount: Int) -> CGEvent? {
        guard let setWindowLocation = setWindowLocationFn,
              let nsType = nsType(for: type), windowID != 0 else { return nil }
        let local = windowLocalPoint(global: global, windowFrame: windowFrame)
        let pressure: Float = isButtonEvent(type) && type != .leftMouseUp
            && type != .rightMouseUp && type != .otherMouseUp ? 1 : 0
        buildLock.lock()
        let built = NSEvent.mouseEvent(with: nsType, location: local, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: Int(windowID), context: nil,
                                       eventNumber: eventNumber.next(),
                                       clickCount: clickCount, pressure: pressure)?.cgEvent
        buildLock.unlock()
        guard let event = built else { return nil }
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        event.setIntegerValueField(windowUnderPointerField, value: Int64(windowID))
        event.setIntegerValueField(windowUnderPointerHandlerField, value: Int64(windowID))
        // Global location for hit-testing, window-local for locationInWindow.
        event.location = global
        setWindowLocation(event, local)
        return event
    }

    /// `kCGMouseEventWindowUnderMousePointer`. Declared in CGEventTypes.h
    /// ("Added in 10.5; made public in 10.7") but absent from the Swift
    /// `CGEventField` enum, so it is spelled by raw value.
    private static let windowUnderPointerField = CGEventField(rawValue: 91)!
    /// `kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent`.
    private static let windowUnderPointerHandlerField = CGEventField(rawValue: 92)!
}

/// Minimal lock-guarded counter. The actuation scheduler runs different apps in
/// parallel, so the shared event-number source needs to be safe across them.
final class AtomicCounter {
    private let lock = NSLock()
    private var value = 1

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
