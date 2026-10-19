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
    public static let metaMethods: Set<String> = [
        "ping", "echo", "list_apps", "capabilities", "list_displays", "read_clipboard", "write_clipboard",
    ]

    /// Shared key for the meta methods above.
    public static let metaKey = "$meta"

    /// Whole-display captures: no app state, but they write the per-display
    /// click geometry, so they serialize with each other and never with an
    /// app's own work.
    public static let displayMethods: Set<String> = ["screenshot", "zoom"]

    /// Shared key for the display methods above.
    public static let displayKey = "$display"

    /// Read-only per-app methods: capture never activates anything, but it does
    /// mutate that app's index map and diff baseline, so it serializes against
    /// other work for the same app.
    public static let readOnlyAppMethods: Set<String> = ["get_app_state", "list_windows", "find", "wait_for"]

    /// Methods that actuate. Listed explicitly rather than inferred as
    /// "everything else" so a method added later without a decision here runs
    /// alone instead of silently racing.
    public static let actionMethods: Set<String> = [
        "click", "hover", "press_key", "type_text", "scroll", "set_value", "drag",
        "perform_secondary_action", "select_text", "bring_to_active_space", "menu_select", "open_app",
    ]

    /// Methods a `batch` may run. Everything that does one thing to one app
    /// (or nothing to any), and never `batch` itself.
    public static let batchableMethods: Set<String> = actionMethods
        .union(readOnlyAppMethods)
        .union(["read_clipboard", "write_clipboard"])

    /// Most steps one `batch` may hold.
    public static let maxBatchSteps = 50

    /// How long a batch may keep starting steps. Under the IPC server's 30s
    /// request timeout, which answers the client but cannot stop the handler:
    /// a batch that ran past it would go on clicking and typing after the
    /// client was told it timed out. A step is never started after this, and a
    /// `wait_for` step only gets what is left of it.
    public static let batchBudgetSeconds: TimeInterval = 22

    /// A batch holds one slot for its whole run: the shared app key when every
    /// step that names one names the same app (meta steps such as a clipboard
    /// write fit in any slot), otherwise the whole machine.
    public static func classifyBatch(_ steps: [RequestClass]) -> RequestClass {
        var key: String?
        for step in steps {
            switch step {
            case .exclusive:
                return .exclusive
            case .keyed(let k):
                if k == metaKey { continue }
                if let key, key != k { return .exclusive }
                key = k
            }
        }
        return .keyed(key ?? metaKey)
    }

    /// - Parameters:
    ///   - method: wire method name.
    ///   - appKey: canonical identity of the target app — the pid where it
    ///     resolves, so `"Notes"` and `"com.apple.Notes"` cannot be handed two
    ///     separate slots for one app. nil when the request names no app.
    ///   - background: the effective background flag for this request.
    public static func classify(method: String, appKey: String?, background: Bool) -> RequestClass {
        if metaMethods.contains(method) { return .keyed(metaKey) }
        if displayMethods.contains(method) {
            // `zoom` can target an app's window instead of a display; it then
            // reads that app's capture geometry and captures its window, so it
            // belongs on the app's key, not the shared display one.
            if let appKey, method == "zoom" { return .keyed(appKey) }
            return .keyed(displayKey)
        }
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
