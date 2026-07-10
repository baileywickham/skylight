import Foundation

/// Abstraction over an accessibility node so serialization and diffing are
/// unit-testable with fixtures. The live adapter (LiveAXNode) wraps AXUIElement.
public protocol TreeNode {
    /// Stable identity for the underlying element (CFEqual/CFHash semantics live).
    var identity: AnyHashable { get }
    var role: String { get }
    var title: String? { get }
    var value: String? { get }
    var children: [any TreeNode] { get }
}
