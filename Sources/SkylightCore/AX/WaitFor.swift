import AppKit
import Foundation

/// How long `wait_for` waits: 5s by default, never more than 25s — under the
/// IPC server's 30s request timeout, so a wait that runs out reports why
/// instead of being cut off as a bare timeout.
public func waitTimeoutMs(_ requested: Int?) -> Int {
    min(max(requested ?? 5_000, 0), 25_000)
}

/// Pause between `wait_for` polls.
public let waitPollMs = 200

/// Whether one poll satisfies a wait. Each condition is nil when the caller
/// did not ask for it.
///
/// - elementMatches: how many elements matched the element query.
/// - windowMatched: whether some window title matched.
/// - gone: invert the element and window conditions (wait until nothing matches).
/// - stable: whether the tree is unchanged since the previous poll. Never
///   inverted — "until it stops changing" means the same thing either way.
public func waitConditionMet(elementMatches: Int?, windowMatched: Bool?, gone: Bool, stable: Bool?) -> Bool {
    if let elementMatches, (elementMatches > 0) == gone { return false }
    if let windowMatched, windowMatched == gone { return false }
    if let stable, !stable { return false }
    return true
}

/// Polls an app until `input`'s condition holds, then returns the matches.
/// Throws `timeout` (with what it saw last) when the time runs out, so a wait
/// that never came true is never mistaken for one that did.
///
/// A missing window is not an error while waiting — it is usually what is
/// being waited out (an app still launching, a dialog not yet up) — so polls
/// without one count as zero matches and an unstable tree.
public func waitFor(_ input: WaitForInput, app: NSRunningApplication, capture: AXCapture) throws -> WaitForResult {
    let query = ElementQuery(role: input.role, text: input.text)
    let windowTitle = input.window_title.flatMap { $0.isEmpty ? nil : $0.lowercased() }
    let wantsStable = input.stable ?? false
    let gone = input.gone ?? false
    guard !query.isEmpty || windowTitle != nil || wantsStable else {
        throw SkyServiceError(code: .invalidParams,
                              message: "wait_for needs a condition: role and/or text, window_title, or stable")
    }
    let timeoutMs = waitTimeoutMs(input.timeout_ms)
    let start = Date()
    var previousLines: [String]?
    var lastSeen = "nothing yet"
    while true {
        var outcome: FindOutcome?
        if !query.isEmpty || wantsStable {
            do {
                outcome = try capture.find(app: app, windowID: input.window_id, rootIndex: input.root_element_index,
                                           query: query, limit: maxFindResults)
            } catch let error as SkyServiceError where error.code == .noFocusedWindow {
                outcome = nil
            }
        }
        let windowMatched: Bool? = try windowTitle.map { wanted in
            try capture.windowListings(of: app).contains { $0.info.title?.lowercased().contains(wanted) ?? false }
        }
        let stable: Bool? = wantsStable ? (outcome != nil && outcome?.lines == previousLines) : nil
        // How much moved, so a wait that never settles says whether it is one
        // ticking clock or a whole view reloading.
        var changedLines: Int?
        if let prev = previousLines, let cur = outcome?.lines {
            changedLines = Set(prev).symmetricDifference(cur).count
        }
        previousLines = outcome?.lines
        // A poll that found no window saw nothing: for an appear-wait that is
        // zero matches, but for `gone` it is not evidence of absence (a focus
        // gap while a sheet animates in, a stale window_id), so it cannot
        // satisfy the wait.
        let elementMatches: Int? = query.isEmpty ? nil
            : outcome.map { $0.matches.count } ?? (gone ? 1 : 0)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        if waitConditionMet(elementMatches: elementMatches, windowMatched: windowMatched, gone: gone, stable: stable) {
            return WaitForResult(elapsed_ms: elapsed, matches: gone ? [] : (outcome?.matches ?? []))
        }
        lastSeen = [
            elementMatches.map { "\($0) matching element(s)" },
            windowMatched.map { $0 ? "a matching window" : "no matching window" },
            stable.map { stable in
                if stable { return "a stable tree" }
                return changedLines.map { "a tree still changing (\($0) line(s) differed from the poll before)" }
                    ?? "no tree to compare yet"
            },
        ].compactMap { $0 }.joined(separator: ", ")
        if elapsed >= timeoutMs { break }
        usleep(UInt32(min(waitPollMs, max(timeoutMs - elapsed, 1))) * 1000)
    }
    throw SkyServiceError(code: .timeout,
                          message: "wait_for: condition not met after \(timeoutMs)ms (last poll saw \(lastSeen))")
}
