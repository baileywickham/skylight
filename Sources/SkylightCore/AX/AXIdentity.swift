import ApplicationServices
import Foundation

/// Hashable wrapper giving AXUIElement CFEqual/CFHash identity semantics, so
/// ElementIndexMap keys stay stable across captures of the same element.
public struct AXIdentity: Hashable {
    public let element: AXUIElement
    public init(element: AXUIElement) { self.element = element }

    public static func == (lhs: AXIdentity, rhs: AXIdentity) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}
