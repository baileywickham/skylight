import AppKit
import ApplicationServices
import Foundation

/// CGEvent keyboard/mouse events posted to the session tap land in the
/// FRONTMOST app — which, when Claude runs `tsx` from the Bash tool, is the
/// terminal. So in the default (foreground) mode, before keyboard or
/// coordinate actions: activate the target app, raise the window, and wait.
///
/// Background mode (`SKYLIGHT_BACKGROUND=1` on the daemon) skips this call
/// entirely and delivers synthetic events per-pid instead — see
/// `eventDestination`. The trade-off that made activation-first the DEFAULT
/// still stands: Chromium/Electron and other NSApp.isActive-checking apps can
/// mishandle input received while inactive, and menu key equivalents (Cmd+c,
/// Cmd+v, …) generally do not fire in a non-frontmost app because the menu bar
/// belongs to the frontmost one. Background delivery is therefore best-effort
/// for coordinate/keyboard actions and reliable for AX element actions.
public func activateAndRaise(app: NSRunningApplication, window: AXUIElement) {
    app.activate()
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    let deadline = Date().addingTimeInterval(2.0)
    while !app.isActive && Date() < deadline {
        usleep(20_000)
    }
    // Small settle so the raise/space-switch completes before events post.
    usleep(80_000)
}

/// Where a synthesized CGEvent is delivered.
public enum EventDestination: Equatable {
    /// Session-wide HID tap — the event lands in the frontmost app (default).
    case session
    /// Directly into one app's event queue via CGEventPostToPid, regardless of
    /// which app is frontmost (background mode).
    case pid(pid_t)
}

/// Foreground (default) mode activates the target before every action so
/// session-tap events land in it and post-action screenshots are unobscured.
/// Background mode never activates: AX element actions (press/set-value/
/// select-range) deliver straight to the element without focus, and synthetic
/// events go per-pid.
public func shouldActivate(background: Bool) -> Bool {
    !background
}

/// Selects the delivery route for synthetic keyboard/mouse events. Pure so the
/// background-mode routing is unit-testable without posting real events.
public func eventDestination(background: Bool, targetPid: pid_t) -> EventDestination {
    background ? .pid(targetPid) : .session
}
