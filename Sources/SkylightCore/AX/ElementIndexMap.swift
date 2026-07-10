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

    public func beginCapture() {
        latestCapture.removeAll()
    }

    public func noteCaptured(_ index: Int) {
        latestCapture.insert(index)
    }

    public func isInLatestCapture(_ index: Int) -> Bool {
        latestCapture.contains(index)
    }
}
