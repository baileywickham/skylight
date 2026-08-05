import Foundation

/// Decides how much of the machine a request needs to itself.
///
/// The rule in one line: **background work is per-app, foreground work is
/// global.** Background actions route synthetic events straight into one pid
/// and never touch focus or the cursor, so two of them against different apps
/// cannot interfere. Foreground actions activate an app and move the real
/// cursor — shared state, so they run alone.
///
/// Pure, so the whole policy is a table in the tests rather than behavior
/// spread across the daemon.
public enum RequestClassifier {
    /// Methods that touch neither app state nor input, so they never queue
    /// behind actuation.
    public static let metaMethods: Set<String> = ["ping", "echo", "list_apps", "capabilities"]

    /// Shared key for the meta methods above.
    public static let metaKey = "$meta"

    /// Read-only per-app methods: capture never activates anything, but it does
    /// mutate that app's index map and diff baseline, so it serializes against
    /// other work for the same app.
    public static let readOnlyAppMethods: Set<String> = ["get_app_state", "list_windows"]

    /// Methods that actuate. Listed explicitly rather than inferred as
    /// "everything else" so a method added later without a decision here runs
    /// alone instead of silently racing.
    public static let actionMethods: Set<String> = [
        "click", "press_key", "type_text", "scroll", "set_value", "drag",
        "perform_secondary_action", "select_text",
    ]

    /// - Parameters:
    ///   - method: wire method name.
    ///   - appKey: canonical identity of the target app — the pid where it
    ///     resolves, so `"Notes"` and `"com.apple.Notes"` cannot be handed two
    ///     separate slots for one app. nil when the request names no app.
    ///   - background: the effective background flag for this request.
    public static func classify(method: String, appKey: String?, background: Bool) -> RequestClass {
        if metaMethods.contains(method) { return .keyed(metaKey) }
        // No resolvable target: fall back to exclusive. Such a request is
        // about to fail with app_not_found anyway, and guessing a key for it
        // could collide with a real app's slot.
        guard let appKey else { return .exclusive }
        if readOnlyAppMethods.contains(method) { return .keyed(appKey) }
        // Actions: parallel only in background mode. Anything unrecognized
        // falls through to exclusive.
        guard actionMethods.contains(method) else { return .exclusive }
        return background ? .keyed(appKey) : .exclusive
    }
}
