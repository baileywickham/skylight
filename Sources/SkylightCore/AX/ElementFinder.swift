import Foundation

/// What `find` / `wait_for` look for. Every given field must match; a query
/// with no fields matches nothing (callers reject it before walking).
public struct ElementQuery: Equatable {
    /// Lowercased, "AX"-prefixed role, or nil for any role.
    public let role: String?
    /// Lowercased substring of the label or value, or nil for any text.
    public let text: String?

    public init(role: String?, text: String?) {
        self.role = role
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .flatMap { $0.isEmpty ? nil : ($0.hasPrefix("ax") ? $0 : "ax" + $0) }
        self.text = text.flatMap { $0.isEmpty ? nil : $0.lowercased() }
    }

    public var isEmpty: Bool { role == nil && text == nil }

    public func matches(role nodeRole: String, title: String?, value: String?) -> Bool {
        if let role, nodeRole.lowercased() != role { return false }
        if let text {
            let haystacks = [title, value].compactMap { $0?.lowercased() }
            if !haystacks.contains(where: { $0.contains(text) }) { return false }
        }
        return true
    }
}

/// Default and ceiling for `find`'s `max_results`.
public let defaultFindResults = 50
public let maxFindResults = 500

/// How many results a `find` returns: 50 by default, between 1 and 500.
public func findResultLimit(_ requested: Int?) -> Int {
    min(max(requested ?? defaultFindResults, 1), maxFindResults)
}

public struct FindOutcome {
    public let matches: [FoundElement]
    /// More nodes matched than the result limit.
    public let truncated: Bool
    /// Every visited node's line, in walk order — what `wait_for`'s `stable`
    /// compares between polls.
    public let lines: [String]
}

/// Walks a tree like `AXTreeSerializer` — same caps, same sticky indices —
/// but returns only the nodes matching `query`, so a caller can locate a
/// control without reading (or paying for) the whole window.
///
/// Every visited node is noted as captured, so a returned index is
/// immediately actionable. The walk never clears the previous capture's set:
/// it may stop at the node budget, and an element it did not reach has not
/// been shown to be gone.
public func findElements(root: any TreeNode, query: ElementQuery, map: ElementIndexMap,
                         caps: TreeCaps = .standard, limit: Int = defaultFindResults) -> FindOutcome {
    map.beginCapture(preservingPrevious: true)
    var matches: [FoundElement] = []
    var truncated = false
    var lines: [String] = []
    var budget = caps.maxNodes
    // Labelled ancestors of the node being visited, outermost first.
    var ancestors: [String] = []

    func label(role: String, title: String?) -> String {
        guard let title, !title.isEmpty else { return role }
        return "\(role) \"\(title)\""
    }

    func walk(_ node: any TreeNode, depth: Int) {
        guard depth < caps.maxDepth, budget > 0 else { return }
        budget -= 1
        let index = map.index(for: node.identity)
        map.noteCaptured(index)
        let role = node.role
        let title = node.title
        let value = node.value
        var line = "[\(index)] \(role)"
        if let title, !title.isEmpty { line += " \"\(title)\"" }
        if let value, !value.isEmpty { line += " value=\"\(value)\"" }
        lines.append(line)
        // Matched against the full value, not the display copy in the line.
        if !query.isEmpty, query.matches(role: role, title: title, value: query.text == nil ? value : node.searchValue) {
            if matches.count < limit {
                matches.append(FoundElement(element_index: index, role: role, title: title, value: value,
                                            line: line, ancestors: ancestors.suffix(3).joined(separator: " > ")))
            } else {
                truncated = true
            }
        }
        // Only labelled ancestors and the window itself say where a node is;
        // a chain of anonymous AXGroups is noise.
        let pushed = depth == 0 || (title.map { !$0.isEmpty } ?? false)
        if pushed { ancestors.append(label(role: role, title: title)) }
        for child in node.children {
            guard budget > 0 else { break }
            walk(child, depth: depth + 1)
        }
        if pushed { ancestors.removeLast() }
    }

    walk(root, depth: 0)
    return FindOutcome(matches: matches, truncated: truncated, lines: lines)
}

/// Normalizes a menu title for matching: case-insensitive, whitespace-trimmed,
/// and "..." equal to "…" (menus use the ellipsis character; people type dots).
public func normalizedMenuTitle(_ title: String) -> String {
    title.replacingOccurrences(of: "...", with: "…")
        .trimmingCharacters(in: .whitespaces)
        .lowercased()
}

/// Scroll-bar value after scrolling `pages` visible pages, clamped to 0...1.
///
/// An AX scroll bar's value is the scroll position as a fraction of the
/// scrollable range (content minus visible). One page moves the content by
/// the visible length, so one page is `visible / (content - visible)` of the
/// range. `towardEnd` is down/right. nil when nothing can scroll.
public func scrollBarTarget(current: Double, visible: Double, content: Double,
                            pages: Double, towardEnd: Bool) -> Double? {
    let range = content - visible
    guard range > 0, visible > 0 else { return nil }
    let step = (visible / range) * pages * (towardEnd ? 1 : -1)
    return min(max(current + step, 0), 1)
}
