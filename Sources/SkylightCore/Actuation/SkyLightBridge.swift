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

    public init(focus_without_raise: Bool, trusted_events: Bool) {
        self.focus_without_raise = focus_without_raise
        self.trusted_events = trusted_events
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

    public static func capabilities() -> SkyLightCapabilities {
        SkyLightCapabilities(
            focus_without_raise: canFocusWithoutRaise,
            trusted_events: trustedEventsEnabled && postEventRecordFn != nil)
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
