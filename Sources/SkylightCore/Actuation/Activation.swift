import AppKit
import ApplicationServices
import Foundation

/// CGEvent keyboard/mouse events land in the FRONTMOST app — which, when Claude
/// runs `tsx` from the Bash tool, is the terminal. So before keyboard or
/// coordinate actions: activate the target app, raise the window, and wait.
/// (CGEventPostToPid is deliberately not used: Chromium & NSApp.isActive-checking
/// apps mishandle input received while inactive.)
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
