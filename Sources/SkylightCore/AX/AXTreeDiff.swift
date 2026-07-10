import Foundation

/// Diff two serialized captures keyed by sticky element index. Because indices
/// never move (ElementIndexMap), a per-index comparison is exact: an index in
/// current-only is added (+), previous-only is removed (-), present in both with
/// different text is changed (~). Unchanged nodes are omitted so the model sees
/// only what moved. Truncation markers (index -1) are ignored in the diff.
public func diffTrees(previous: [TreeLine], current: [TreeLine]) -> String {
    let prev = Dictionary(previous.filter { $0.index >= 0 }.map { ($0.index, $0) },
                          uniquingKeysWith: { a, _ in a })
    let curr = Dictionary(current.filter { $0.index >= 0 }.map { ($0.index, $0) },
                          uniquingKeysWith: { a, _ in a })
    var entries: [(index: Int, text: String)] = []
    for index in Set(prev.keys).union(curr.keys) {
        switch (prev[index], curr[index]) {
        case let (nil, .some(c)):
            entries.append((index, "+ " + c.text))
        case let (.some(p), nil):
            entries.append((index, "- " + p.text))
        case let (.some(p), .some(c)) where p.text != c.text:
            entries.append((index, "~ " + c.text))
        default:
            break // unchanged
        }
    }
    if entries.isEmpty { return "(no changes)" }
    return entries.sorted { $0.index < $1.index }.map(\.text).joined(separator: "\n")
}
