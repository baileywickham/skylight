import Foundation

public struct TreeCaps: Equatable {
    public let maxDepth: Int
    public let maxNodes: Int
    public static let standard = TreeCaps(maxDepth: 30, maxNodes: 5000)
    public init(maxDepth: Int, maxNodes: Int) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
    }
}

/// One serialized node. `index == -1` marks a truncation marker line.
public struct TreeLine: Equatable, Codable {
    public let index: Int
    public let depth: Int
    public let text: String
    public init(index: Int, depth: Int, text: String) {
        self.index = index
        self.depth = depth
        self.text = text
    }
}

public struct SerializedTree {
    public let text: String
    public let lines: [TreeLine]
    public init(lines: [TreeLine]) {
        self.lines = lines
        self.text = lines.map { String(repeating: "  ", count: $0.depth) + $0.text }.joined(separator: "\n")
    }
}

public final class AXTreeSerializer {
    private let caps: TreeCaps

    public init(caps: TreeCaps = .standard) {
        self.caps = caps
    }

    public func serialize(root: any TreeNode, map: ElementIndexMap) -> SerializedTree {
        map.beginCapture()
        var lines: [TreeLine] = []
        var nodeBudget = caps.maxNodes
        walk(root, depth: 0, map: map, lines: &lines, nodeBudget: &nodeBudget)
        return SerializedTree(lines: lines)
    }

    private func walk(_ node: any TreeNode, depth: Int, map: ElementIndexMap,
                      lines: inout [TreeLine], nodeBudget: inout Int) {
        if depth >= caps.maxDepth {
            lines.append(TreeLine(index: -1, depth: depth,
                                  text: "[…] truncated (max depth \(caps.maxDepth) reached)"))
            return
        }
        if nodeBudget <= 0 {
            appendNodeCapMarkerIfNeeded(depth: depth, lines: &lines)
            return
        }
        nodeBudget -= 1
        let index = map.index(for: node.identity)
        map.noteCaptured(index)
        var text = "[\(index)] \(node.role)"
        if let title = node.title, !title.isEmpty {
            text += " \"\(title)\""
        }
        if let value = node.value, !value.isEmpty {
            text += " value=\"\(value)\""
        }
        lines.append(TreeLine(index: index, depth: depth, text: text))
        for child in node.children {
            if nodeBudget <= 0 {
                appendNodeCapMarkerIfNeeded(depth: depth + 1, lines: &lines)
                return
            }
            walk(child, depth: depth + 1, map: map, lines: &lines, nodeBudget: &nodeBudget)
        }
    }

    private func appendNodeCapMarkerIfNeeded(depth: Int, lines: inout [TreeLine]) {
        let marker = "[…] truncated (max nodes \(caps.maxNodes) reached)"
        if lines.last?.text != marker {
            lines.append(TreeLine(index: -1, depth: depth, text: marker))
        }
    }
}
