import XCTest
import SkylightCore

/// Fixture node so serializer + index map are tested without any live AX.
struct FixtureNode: TreeNode {
    let id: String
    let role: String
    let title: String?
    let value: String?
    let kids: [FixtureNode]
    var identity: AnyHashable { id }
    var children: [any TreeNode] { kids }
    init(_ id: String, _ role: String, title: String? = nil, value: String? = nil, kids: [FixtureNode] = []) {
        self.id = id; self.role = role; self.title = title; self.value = value; self.kids = kids
    }
}

final class SerializerTests: XCTestCase {
    func testSerializesIndexedIndentedText() {
        let tree = FixtureNode("w", "AXWindow", title: "Untitled", kids: [
            FixtureNode("t", "AXToolbar", kids: [FixtureNode("b", "AXButton", title: "Bold")]),
            FixtureNode("a", "AXTextArea", value: "hello"),
        ])
        let out = AXTreeSerializer().serialize(root: tree, map: ElementIndexMap())
        XCTAssertEqual(out.text, """
        [0] AXWindow "Untitled"
          [1] AXToolbar
            [2] AXButton "Bold"
          [3] AXTextArea value="hello"
        """)
        XCTAssertEqual(out.lines.count, 4)
        XCTAssertEqual(out.lines[2], TreeLine(index: 2, depth: 2, text: "[2] AXButton \"Bold\""))
    }

    func testIndicesAreStickyAcrossCapturesAndNeverReused() {
        let map = ElementIndexMap()
        let serializer = AXTreeSerializer()
        let first = FixtureNode("w", "AXWindow", kids: [FixtureNode("b1", "AXButton", title: "One"),
                                                        FixtureNode("b2", "AXButton", title: "Two")])
        _ = serializer.serialize(root: first, map: map) // w=0, b1=1, b2=2

        // b1 disappears, b3 appears: b2 must KEEP index 2, b3 gets fresh 3 (1 is never reused).
        let second = FixtureNode("w", "AXWindow", kids: [FixtureNode("b2", "AXButton", title: "Two"),
                                                         FixtureNode("b3", "AXButton", title: "Three")])
        let out = serializer.serialize(root: second, map: map)
        XCTAssertEqual(out.text, """
        [0] AXWindow
          [2] AXButton "Two"
          [3] AXButton "Three"
        """)
        XCTAssertEqual(map.identity(forIndex: 1), AnyHashable("b1"), "old identity still resolvable")
        XCTAssertFalse(map.isInLatestCapture(1))
        XCTAssertTrue(map.isInLatestCapture(2))
    }

    func testDepthCapEmitsTruncationMarker() {
        var leaf = FixtureNode("leaf", "AXGroup")
        for i in (0..<5).reversed() { leaf = FixtureNode("g\(i)", "AXGroup", kids: [leaf]) }
        let out = AXTreeSerializer(caps: TreeCaps(maxDepth: 3, maxNodes: 5000)).serialize(root: leaf, map: ElementIndexMap())
        XCTAssertTrue(out.text.contains("[…] truncated (max depth 3 reached)"))
        XCTAssertFalse(out.text.contains("leaf"))
    }

    func testNodeCapEmitsTruncationMarker() {
        let kids = (0..<10).map { FixtureNode("k\($0)", "AXButton", title: "B\($0)") }
        let tree = FixtureNode("w", "AXWindow", kids: kids)
        let out = AXTreeSerializer(caps: TreeCaps(maxDepth: 30, maxNodes: 4)).serialize(root: tree, map: ElementIndexMap())
        XCTAssertTrue(out.text.contains("[…] truncated (max nodes 4 reached)"))
        XCTAssertEqual(out.lines.filter { $0.index >= 0 }.count, 4)
    }

    func testTruncationMarkerLinesHaveIndexMinusOne() {
        let tree = FixtureNode("w", "AXWindow", kids: (0..<3).map { FixtureNode("k\($0)", "AXButton") })
        let out = AXTreeSerializer(caps: TreeCaps(maxDepth: 30, maxNodes: 2)).serialize(root: tree, map: ElementIndexMap())
        XCTAssertTrue(out.lines.contains { $0.index == -1 })
    }
}
