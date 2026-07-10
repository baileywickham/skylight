import XCTest
import SkylightCore

final class DiffTests: XCTestCase {
    private func line(_ index: Int, _ depth: Int, _ text: String) -> TreeLine {
        TreeLine(index: index, depth: depth, text: text)
    }

    func testNoChangesReported() {
        let lines = [line(0, 0, "[0] AXWindow"), line(1, 1, "[1] AXButton \"Go\"")]
        XCTAssertEqual(diffTrees(previous: lines, current: lines), "(no changes)")
    }

    func testAddedRemovedAndChangedLinesByStickyIndex() {
        let previous = [
            line(0, 0, "[0] AXWindow"),
            line(1, 1, "[1] AXButton \"Go\""),
            line(2, 1, "[2] AXTextField value=\"old\""),
        ]
        let current = [
            line(0, 0, "[0] AXWindow"),
            line(2, 1, "[2] AXTextField value=\"new\""), // changed
            line(3, 1, "[3] AXButton \"Stop\""),          // added; index 1 removed
        ]
        let diff = diffTrees(previous: previous, current: current)
        XCTAssertTrue(diff.contains("- [1] AXButton \"Go\""))
        XCTAssertTrue(diff.contains("~ [2] AXTextField value=\"new\""))
        XCTAssertTrue(diff.contains("+ [3] AXButton \"Stop\""))
        XCTAssertFalse(diff.contains("[0] AXWindow"), "unchanged nodes are omitted")
    }

    // MARK: - Branches the brief leaves untested

    func testEmptyPreviousReportsEverythingAdded() {
        let current = [line(0, 0, "[0] AXWindow"), line(4, 1, "[4] AXButton \"Go\"")]
        XCTAssertEqual(diffTrees(previous: [], current: current),
                       "+ [0] AXWindow\n+ [4] AXButton \"Go\"")
    }

    func testEmptyCurrentReportsEverythingRemoved() {
        let previous = [line(0, 0, "[0] AXWindow"), line(1, 1, "[1] AXButton \"Go\"")]
        XCTAssertEqual(diffTrees(previous: previous, current: []),
                       "- [0] AXWindow\n- [1] AXButton \"Go\"")
    }

    func testEntriesAreSortedByIndex() {
        let previous = [line(7, 0, "[7] AXGroup")]
        let current = [line(9, 0, "[9] AXGroup"), line(2, 1, "[2] AXButton")]
        XCTAssertEqual(diffTrees(previous: previous, current: current),
                       "+ [2] AXButton\n- [7] AXGroup\n+ [9] AXGroup")
    }

    func testTruncationMarkersAreIgnored() {
        // index == -1 marks truncation markers; they carry no sticky identity and
        // must never surface as added/removed/changed noise.
        let previous = [
            line(0, 0, "[0] AXWindow"),
            line(-1, 1, "[…] truncated (max depth 30 reached)"),
        ]
        let current = [
            line(0, 0, "[0] AXWindow"),
            line(-1, 2, "[…] truncated (max nodes 5000 reached)"),
        ]
        XCTAssertEqual(diffTrees(previous: previous, current: current), "(no changes)")
    }

    func testDepthOnlyChangeWithSameTextIsNotReported() {
        // The diff keys on sticky index + text; a reparent that keeps the same
        // serialized text is invisible by design (text carries the index).
        let previous = [line(0, 0, "[0] AXWindow"), line(1, 1, "[1] AXButton \"Go\"")]
        let current = [line(0, 0, "[0] AXWindow"), line(1, 2, "[1] AXButton \"Go\"")]
        XCTAssertEqual(diffTrees(previous: previous, current: current), "(no changes)")
    }

    func testMarkerLikeCharactersInsideNodeTextCannotForgeDiffLines() {
        // Values are sanitized to one line upstream, so markers are only ever at
        // the start of a diff line, immediately followed by "[<index>] ". A value
        // containing "+ [9] ..." stays embedded in its own single entry.
        let previous = [line(0, 0, "[0] AXTextField value=\"a\"")]
        let current = [line(0, 0, "[0] AXTextField value=\"x + [9] AXButton - [7] y\"")]
        let diff = diffTrees(previous: previous, current: current)
        let diffLines = diff.split(separator: "\n")
        XCTAssertEqual(diffLines.count, 1, "one changed node yields exactly one diff line")
        XCTAssertEqual(diffLines[0], "~ [0] AXTextField value=\"x + [9] AXButton - [7] y\"")
    }
}
