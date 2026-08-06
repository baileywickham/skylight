import Foundation

/// How a request may overlap with others.
public enum RequestClass: Equatable {
    /// Runs alone: nothing else may be in flight. Foreground actions activate
    /// apps and move the real cursor, which is global state.
    case exclusive
    /// Runs concurrently with other keys, serialized against its own key.
    /// The key is the target app, so two agents driving different apps
    /// overlap while two requests for one app never do.
    case keyed(String)
}

/// Admission control for actuation.
///
/// Replaces the single global serial queue: background work against different
/// apps runs in parallel (per-pid event routing makes that safe), while
/// foreground work still runs alone.
///
/// Built on NSCondition rather than a concurrent DispatchQueue with barriers:
/// barrier blocks only exclude work submitted *directly* to the concurrent
/// queue, not work arriving through queues that target it, which is exactly
/// the topology per-key serialization would need.
public final class ActuationScheduler {
    private let condition = NSCondition()
    private var activeKeys: Set<String> = []
    private var exclusiveActive = false
    /// Exclusive requests waiting for admission. New keyed work yields to them,
    /// so a steady stream of background actions cannot starve a foreground one.
    private var exclusiveWaiting = 0

    public init() {}

    /// Runs `body` on the calling thread once admitted, releasing the slot
    /// afterwards — including when `body` throws.
    public func run<T>(_ requestClass: RequestClass, _ body: () throws -> T) rethrows -> T {
        acquire(requestClass)
        defer { release(requestClass) }
        return try body()
    }

    private func acquire(_ requestClass: RequestClass) {
        condition.lock()
        defer { condition.unlock() }
        switch requestClass {
        case .exclusive:
            exclusiveWaiting += 1
            while exclusiveActive || !activeKeys.isEmpty {
                condition.wait()
            }
            exclusiveWaiting -= 1
            exclusiveActive = true
        case .keyed(let key):
            while exclusiveActive || exclusiveWaiting > 0 || activeKeys.contains(key) {
                condition.wait()
            }
            activeKeys.insert(key)
        }
    }

    private func release(_ requestClass: RequestClass) {
        condition.lock()
        defer { condition.unlock() }
        switch requestClass {
        case .exclusive: exclusiveActive = false
        case .keyed(let key): activeKeys.remove(key)
        }
        condition.broadcast()
    }

    /// Test/introspection hook: how many keyed requests are running right now.
    public var activeKeyCount: Int {
        condition.lock(); defer { condition.unlock() }
        return activeKeys.count
    }

    /// Test/introspection hook: exclusive requests waiting for admission. Lets a
    /// test wait for "the exclusive request has registered" instead of sleeping
    /// and hoping — a fixed sleep is exactly what makes such tests flake on a
    /// loaded machine.
    public var exclusiveWaitingCount: Int {
        condition.lock(); defer { condition.unlock() }
        return exclusiveWaiting
    }
}
