import AppKit
import ApplicationServices
import Foundation

/// CGEvent keyboard/mouse events posted to the session tap land in the
/// FRONTMOST app — which, when Claude runs `tsx` from the Bash tool, is the
/// terminal. So in the default (foreground) mode, before keyboard or
/// coordinate actions: activate the target app, raise the window, and wait.
///
/// Background mode (`SKYLIGHT_BACKGROUND=1` on the daemon) skips this call
/// entirely, delivering synthetic events per-pid (see `eventDestination`) after
/// making the target AppKit-active without raising it (see
/// `focusWithoutRaise`). That pairing is what removed the original caveat:
/// menu key equivalents now fire in a non-frontmost app because the app
/// believes it is active, and Chromium accepts input once primed (see
/// `needsUserActivationPrimer`). Where the private symbols are unavailable
/// `focusWithoutRaise` no-ops and background delivery falls back to the older
/// best-effort behavior: reliable for AX element actions, approximate for
/// coordinate/keyboard ones.
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

/// Which process an event record is posted to during focus-without-raise.
public enum FocusRecordDestination: Equatable {
    /// The process that is frontmost right now — told to go inactive.
    case frontProcess
    /// The process we are routing input to — told to go active, then given the
    /// key-window pair.
    case targetProcess
}

public struct FocusStep: Equatable {
    public let destination: FocusRecordDestination
    public let record: [UInt8]
    public init(destination: FocusRecordDestination, record: [UInt8]) {
        self.destination = destination
        self.record = record
    }
}

/// The ordered records that make `targetWindowID` key and its app AppKit-active
/// WITHOUT raising it. Pure, so the sequence is asserted in tests rather than
/// inferred from live window-server behavior.
///
/// When the target app is already frontmost there is nothing to deactivate, so
/// only the key-window pair is posted.
public func focusWithoutRaiseSequence(targetWindowID: CGWindowID,
                                      frontWindowID: CGWindowID,
                                      frontIsTarget: Bool) -> [FocusStep] {
    var steps: [FocusStep] = []
    if !frontIsTarget {
        steps.append(FocusStep(destination: .frontProcess,
                               record: EventRecord.activation(windowID: frontWindowID, activate: false)))
        steps.append(FocusStep(destination: .targetProcess,
                               record: EventRecord.activation(windowID: targetWindowID, activate: true)))
    }
    steps += EventRecord.keyWindow(windowID: targetWindowID)
        .map { FocusStep(destination: .targetProcess, record: $0) }
    return steps
}

/// Makes `window`'s app AppKit-active and `window` its key window without
/// raising either — the background-mode counterpart of `activateAndRaise`.
///
/// This is what lets menu key equivalents (Cmd+c, Cmd+v) fire in a
/// non-frontmost app: NSMenu matches key equivalents only for the app it
/// believes is active, and posting these records flips exactly that belief
/// while deliberately never calling SLPSSetFrontProcessWithOptions (which is
/// what would raise the window and switch Spaces).
///
/// Returns false — and changes nothing — when the private symbols or the
/// window id are unavailable, leaving background mode exactly as it behaved
/// before: per-pid events only, best-effort.
@discardableResult
public func focusWithoutRaise(app: NSRunningApplication, window: AXUIElement) -> Bool {
    guard SkyLightBridge.canFocusWithoutRaise,
          let targetWindowID = axWindowID(of: window),
          let targetPSN = SkyLightBridge.processSerialNumber(forPid: app.processIdentifier)
    else { return false }

    let front = SkyLightBridge.frontProcess()
    let frontIsTarget = front.map { psnEquals($0, targetPSN) } ?? false
    let steps = focusWithoutRaiseSequence(targetWindowID: targetWindowID,
                                          frontWindowID: 0,
                                          frontIsTarget: frontIsTarget)
    var allPosted = true
    for step in steps {
        switch step.destination {
        case .frontProcess:
            guard let front else { allPosted = false; continue }
            allPosted = SkyLightBridge.post(record: step.record, to: front) && allPosted
        case .targetProcess:
            allPosted = SkyLightBridge.post(record: step.record, to: targetPSN) && allPosted
        }
    }
    return allPosted
}

/// Chromium gates synthetic input on a user-activation signal: a click posted
/// into a backgrounded Chromium window is dropped at the renderer IPC boundary
/// unless it follows a trusted user gesture. Posting a throwaway down/up pair
/// outside every window first makes the real click land as a continuation of
/// it. AppKit apps need none of this, so the primer is limited to the Chromium
/// family (including Electron shells, which embed the same renderer).
public func needsUserActivationPrimer(bundleID: String?) -> Bool {
    guard let bundleID = bundleID?.lowercased() else { return false }
    // Safari is WebKit, not Chromium, and does not gate synthetic input.
    if bundleID.hasPrefix("com.apple.safari") { return false }
    let chromiumMarkers = ["google.chrome", "microsoft.edgemac", "brave.browser",
                           "company.thebrowser", "chromium", "electron", "vivaldi", "opera"]
    return chromiumMarkers.contains { bundleID.contains($0) }
}

/// A point guaranteed to be outside every window, so the primer gesture cannot
/// activate anything it lands on.
public let userActivationPrimerPoint = CGPoint(x: -1, y: -1)

/// Whether an action delivers synthetic CGEvents (so it needs the target to be
/// AppKit-active) or drives the AX element directly (which works regardless of
/// focus). Background mode only performs the focus-without-raise dance for the
/// former: flipping the user's frontmost app to inactive is a real, if brief,
/// disturbance and pure AX actions gain nothing from it.
public func deliversSyntheticEvents(action: ActuatorAction) -> Bool {
    switch action {
    case .coordinateClick, .pressKey, .typeText, .scroll, .drag:
        return true
    case .elementClick, .setValue, .performSecondaryAction, .selectText:
        return false
    }
}

/// The actions the daemon can perform, split by how they reach the app.
public enum ActuatorAction: Equatable {
    case elementClick
    case coordinateClick
    case pressKey
    case typeText
    case scroll
    case setValue
    case drag
    case performSecondaryAction
    case selectText
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
