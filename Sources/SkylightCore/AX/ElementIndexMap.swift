import Foundation

/// Sticky element→index map, one per target app, kept for the session's lifetime.
/// An element seen before keeps its index; new elements get fresh indices;
/// indices are NEVER reused — this is what makes diffs coherent and staleness
/// detectable (an index can go stale, but never silently re-point elsewhere).
public final class ElementIndexMap {
    private var indexByIdentity: [AnyHashable: Int] = [:]
    private var identityByIndex: [Int: AnyHashable] = [:]
    private var latestCapture: Set<Int> = []
    private var nextIndex = 0

    public init() {}

    public func index(for identity: AnyHashable) -> Int {
        if let existing = indexByIdentity[identity] { return existing }
        let assigned = nextIndex
        nextIndex += 1
        indexByIdentity[identity] = assigned
        identityByIndex[assigned] = identity
        return assigned
    }

    public func identity(forIndex index: Int) -> AnyHashable? {
        identityByIndex[index]
    }

    /// Starts a capture's "seen this time" set.
    ///
    /// `preservingPrevious` keeps the previous set instead of clearing it, for
    /// a capture that deliberately walked only part of the window
    /// (get_app_state's `root_element_index`). Staleness means "this element
    /// was gone when we looked"; a scoped capture never looked outside its
    /// subtree, so it has no evidence either way and must not invalidate
    /// indices the caller can still act on.
    public func beginCapture(preservingPrevious: Bool = false) {
        if !preservingPrevious { latestCapture.removeAll() }
    }

    public func noteCaptured(_ index: Int) {
        latestCapture.insert(index)
    }

    public func isInLatestCapture(_ index: Int) -> Bool {
        latestCapture.contains(index)
    }
}
