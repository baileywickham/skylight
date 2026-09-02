import CoreGraphics
import CoreServices
import Darwin
import Foundation

private typealias PostEventRecordToFunc =
    @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> CGError
private typealias GetFrontProcessFunc =
    @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> CGError
private typealias GetProcessForPIDFunc =
    @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

// Spaces (Mission Control desktops). Signatures are the ones yabai and
// friends have used unchanged for a decade; every one is dlsym-probed.
private typealias MainConnectionIDFunc = @convention(c) () -> Int32
private typealias GetActiveSpaceFunc = @convention(c) (Int32) -> UInt64
private typealias CopySpacesForWindowsFunc = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
private typealias MoveWindowsToManagedSpaceFunc = @convention(c) (Int32, CFArray, UInt64) -> Void
private typealias SpaceGetTypeFunc = @convention(c) (Int32, UInt64) -> Int32
private typealias SpaceSetCompatIDFunc = @convention(c) (Int32, UInt64, Int32) -> CGError
private typealias SetWindowListWorkspaceFunc = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, Int32) -> CGError

/// Which private capabilities resolved on this machine. Reported by the
/// `capabilities` method and `skylight doctor` so a macOS update that removes a
/// symbol is visible immediately rather than as mysteriously flaky background
/// actions.
public struct SkyLightCapabilities: Codable, Equatable {
    /// Background actions can make an app AppKit-active without raising it —
    /// the thing that makes menu key equivalents (Cmd+c) fire in a
    /// non-frontmost app. False → background mode behaves as it did before:
    /// per-pid events only, best-effort.
    public let focus_without_raise: Bool
    /// The experimental SkyLight event channel is enabled AND resolved.
    /// Opt-in via SKYLIGHT_TRUSTED_EVENTS=1; see SkyLightBridge.trustedEvents.
    public let trusted_events: Bool
    /// Windows can be asked which Space they are on and moved to the active
    /// Space without switching Spaces (`bring_to_active_space`,
    /// `is_on_active_space` in list_windows). False → both degrade: the flag
    /// is absent and the method fails not_implemented.
    public let space_management: Bool

    public init(focus_without_raise: Bool, trusted_events: Bool, space_management: Bool = false) {
        self.focus_without_raise = focus_without_raise
        self.trusted_events = trusted_events
        self.space_management = space_management
    }
}

/// Dynamically-bound private window-server entry points.
///
/// Same contract as AXWindowBridge (`_AXUIElementGetWindow`): resolve with
/// dlsym, and when a symbol is absent return nil/false so the caller degrades
/// to the documented path instead of failing. Nothing here ever traps — a
/// macOS release that drops these symbols costs background *reliability*, not
/// the daemon.
///
/// Handles and symbols resolve once (lazy static, which is atomic in Swift);
/// every actuation queue shares them.
public enum SkyLightBridge {
    /// SkyLight is already linked into any AppKit process, so the global
    /// handle normally suffices; the explicit framework path is the fallback
    /// for a hypothetical process that has not loaded it.
    private static let handle: UnsafeMutableRawPointer? = {
        if let global = dlopen(nil, RTLD_NOW), dlsym(global, "SLPSPostEventRecordTo") != nil {
            return global
        }
        return dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
            ?? dlopen(nil, RTLD_NOW)
    }()

    /// Tries each spelling in turn — these symbols are inconsistently
    /// underscore-prefixed across macOS releases.
    private static func symbol(_ names: [String]) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        for name in names {
            if let sym = dlsym(handle, name) { return sym }
        }
        return nil
    }

    private static let postEventRecordFn: PostEventRecordToFunc? =
        symbol(["SLPSPostEventRecordTo", "_SLPSPostEventRecordTo"])
            .map { unsafeBitCast($0, to: PostEventRecordToFunc.self) }

    private static let frontProcessFn: GetFrontProcessFunc? =
        symbol(["_SLPSGetFrontProcess", "SLPSGetFrontProcess"])
            .map { unsafeBitCast($0, to: GetFrontProcessFunc.self) }

    /// Carbon's pid→psn lookup. Deprecated since 10.9 but still present and
    /// still the only way to get the psn these event records need. Bound by
    /// dlsym rather than called directly so the build stays warning-free.
    private static let processForPIDFn: GetProcessForPIDFunc? =
        symbol(["GetProcessForPID"])
            .map { unsafeBitCast($0, to: GetProcessForPIDFunc.self) }

    private static let mainConnectionIDFn: MainConnectionIDFunc? =
        symbol(["SLSMainConnectionID", "CGSMainConnectionID", "_CGSDefaultConnection"])
            .map { unsafeBitCast($0, to: MainConnectionIDFunc.self) }
    private static let getActiveSpaceFn: GetActiveSpaceFunc? =
        symbol(["SLSGetActiveSpace", "CGSGetActiveSpace"])
            .map { unsafeBitCast($0, to: GetActiveSpaceFunc.self) }
    private static let copySpacesForWindowsFn: CopySpacesForWindowsFunc? =
        symbol(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"])
            .map { unsafeBitCast($0, to: CopySpacesForWindowsFunc.self) }
    private static let moveWindowsToManagedSpaceFn: MoveWindowsToManagedSpaceFunc? =
        symbol(["SLSMoveWindowsToManagedSpace", "CGSMoveWindowsToManagedSpace"])
            .map { unsafeBitCast($0, to: MoveWindowsToManagedSpaceFunc.self) }
    private static let spaceGetTypeFn: SpaceGetTypeFunc? =
        symbol(["SLSSpaceGetType", "CGSSpaceGetType"])
            .map { unsafeBitCast($0, to: SpaceGetTypeFunc.self) }
    private static let spaceSetCompatIDFn: SpaceSetCompatIDFunc? =
        symbol(["SLSSpaceSetCompatID", "CGSSpaceSetCompatID"])
            .map { unsafeBitCast($0, to: SpaceSetCompatIDFunc.self) }
    private static let setWindowListWorkspaceFn: SetWindowListWorkspaceFunc? =
        symbol(["SLSSetWindowListWorkspace", "CGSSetWindowListWorkspace"])
            .map { unsafeBitCast($0, to: SetWindowListWorkspaceFunc.self) }

    /// Cached window-server connection. Resolved once, like the symbols.
    private static let connectionID: Int32? = mainConnectionIDFn.map { $0() }

    /// The experimental SkyLight event channel is OFF unless explicitly
    /// enabled. Unlike every other symbol here its exact signature is not
    /// verifiable from any public source, and a wrong @convention(c) binding
    /// would crash rather than degrade — which is the one failure mode this
    /// bridge exists to prevent. Opt in with SKYLIGHT_TRUSTED_EVENTS=1.
    public static var trustedEventsEnabled: Bool {
        ["1", "true", "yes"].contains(
            (ProcessInfo.processInfo.environment["SKYLIGHT_TRUSTED_EVENTS"] ?? "").lowercased())
    }

    /// True when the focus-without-raise sequence can actually be performed.
    public static var canFocusWithoutRaise: Bool {
        postEventRecordFn != nil && frontProcessFn != nil && processForPIDFn != nil
    }

    /// True when Spaces can be queried and a window moved between them. Either
    /// move path (managed-space move, or the compat-id workaround yabai uses
    /// on macOS 14.5+) counts; `moveWindow` tries both and verifies.
    public static var canManageSpaces: Bool {
        connectionID != nil && getActiveSpaceFn != nil && copySpacesForWindowsFn != nil
            && (moveWindowsToManagedSpaceFn != nil
                || (spaceSetCompatIDFn != nil && setWindowListWorkspaceFn != nil))
    }

    public static func capabilities() -> SkyLightCapabilities {
        SkyLightCapabilities(
            focus_without_raise: canFocusWithoutRaise,
            trusted_events: trustedEventsEnabled && postEventRecordFn != nil,
            space_management: canManageSpaces)
    }

    // MARK: - Spaces

    /// Space id the user is looking at (on the main display). nil when the
    /// symbols are unavailable.
    public static func activeSpace() -> UInt64? {
        guard let cid = connectionID, let fn = getActiveSpaceFn else { return nil }
        let sid = fn(cid)
        return sid == 0 ? nil : sid
    }

    /// Every Space `windowID` is on (a window normally has one; "all Spaces"
    /// windows have several). nil when unavailable, [] when the window server
    /// does not know the window.
    public static func spaces(forWindow windowID: CGWindowID) -> [UInt64]? {
        guard let cid = connectionID, let fn = copySpacesForWindowsFn else { return nil }
        let ids = [NSNumber(value: windowID)] as CFArray
        // 0x7 = current + other + fullscreen spaces.
        guard let result = fn(cid, 0x7, ids)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return result.map { $0.uint64Value }
    }

    /// nil when the answer is unknowable (symbols missing or window unknown).
    public static func isOnActiveSpace(windowID: CGWindowID) -> Bool? {
        guard let active = activeSpace(), let spaces = spaces(forWindow: windowID), !spaces.isEmpty else {
            return nil
        }
        return spaces.contains(active)
    }

    /// 0 = user desktop, 4 = fullscreen app. A window cannot be moved INTO a
    /// fullscreen Space; callers check this before trying.
    public static func spaceType(_ spaceID: UInt64) -> Int32? {
        guard let cid = connectionID, let fn = spaceGetTypeFn else { return nil }
        return fn(cid, spaceID)
    }

    /// Moves `windowID` to `spaceID` WITHOUT switching Spaces, then verifies by
    /// re-reading the window's Spaces. Tries the direct managed-space move
    /// first; when the window server ignores it (macOS 14.5+ does for
    /// non-injected processes) falls back to the compat-id trick: tag the
    /// target Space with a temporary workspace id, assign the window to that
    /// workspace, untag. Returns whether the window ended up on `spaceID`.
    public static func moveWindow(_ windowID: CGWindowID, toSpace spaceID: UInt64) -> Bool {
        guard let cid = connectionID else { return false }
        let onTarget = { (spaces(forWindow: windowID) ?? []).contains(spaceID) }
        if onTarget() { return true }
        if let move = moveWindowsToManagedSpaceFn {
            move(cid, [NSNumber(value: windowID)] as CFArray, spaceID)
            if onTarget() { return true }
        }
        if let setCompat = spaceSetCompatIDFn, let setWorkspace = setWindowListWorkspaceFn {
            let compat: Int32 = 0x79
            guard setCompat(cid, spaceID, compat) == .success else { return false }
            var wid = UInt32(windowID)
            _ = setWorkspace(cid, &wid, 1, compat)
            _ = setCompat(cid, spaceID, 0)
            if onTarget() { return true }
        }
        return false
    }

    public static func processSerialNumber(forPid pid: pid_t) -> ProcessSerialNumber? {
        guard let fn = processForPIDFn else { return nil }
        var psn = ProcessSerialNumber()
        guard fn(pid, &psn) == noErr else { return nil }
        return psn
    }

    public static func frontProcess() -> ProcessSerialNumber? {
        guard let fn = frontProcessFn else { return nil }
        var psn = ProcessSerialNumber()
        guard fn(&psn) == .success else { return nil }
        return psn
    }

    /// Posts one event record. Returns false when the symbol is unavailable or
    /// the window server rejected the record.
    @discardableResult
    public static func post(record: [UInt8], to psn: ProcessSerialNumber) -> Bool {
        guard let fn = postEventRecordFn else { return false }
        var target = psn
        return withUnsafePointer(to: &target) { psnPtr in
            record.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return false }
                return fn(psnPtr, base) == .success
            }
        }
    }
}

/// Two psns identify the same process. ProcessSerialNumber has no Equatable
/// conformance and its fields are the only identity it has.
public func psnEquals(_ a: ProcessSerialNumber, _ b: ProcessSerialNumber) -> Bool {
    a.highLongOfPSN == b.highLongOfPSN && a.lowLongOfPSN == b.lowLongOfPSN
}
