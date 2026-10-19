import Foundation

/// Abstraction over an accessibility node so serialization and diffing are
/// unit-testable with fixtures. The live adapter (LiveAXNode) wraps AXUIElement.
public protocol TreeNode {
    /// Stable identity for the underlying element (CFEqual/CFHash semantics live).
    var identity: AnyHashable { get }
    var role: String { get }
    var title: String? { get }
    var value: String? { get }
    /// The value in full, for searching: `value` is sanitized and capped for
    /// display, so text past its first 200 characters would be unfindable.
    var searchValue: String? { get }
    var children: [any TreeNode] { get }
}

public extension TreeNode {
    var searchValue: String? { value }
}
