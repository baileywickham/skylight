import XCTest
import SkylightCore

/// Fixture element for the popover parent-climb: an id, a role, and a parent id.
private struct FakeElement: Equatable {
    let id: Int
    let role: String?
    let parentID: Int?
}

private func climb(from id: Int, in elements: [FakeElement]) -> FakeElement? {
    let byID = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
    guard let start = byID[id] else { return nil }
    return climbToPopover(from: start,
                          role: { $0.role },
                          parent: { $0.parentID.flatMap { byID[$0] } })
}

final class MenuBarAppTests: XCTestCase {
    func testFocusedElementIsThePopover() {
        let popover = FakeElement(id: 1, role: "AXPopover", parentID: nil)
        XCTAssertEqual(climb(from: 1, in: [popover]), popover)
    }

    func testClimbsFromNestedControlToPopover() {
        // Popover ← group ← button (the focused element): the climb must walk
        // parent links up to the popover, mirroring an app whose focus sits on
        // a control inside the popover rather than the popover itself.
        let elements = [
            FakeElement(id: 1, role: "AXPopover", parentID: 4),
            FakeElement(id: 2, role: "AXGroup", parentID: 1),
            FakeElement(id: 3, role: "AXButton", parentID: 2),
            FakeElement(id: 4, role: "AXMenuBarItem", parentID: nil),
        ]
        XCTAssertEqual(climb(from: 3, in: elements)?.id, 1)
    }

    func testNoPopoverInParentChainReturnsNil() {
        // A focused status item with no popover open: the chain tops out at
        // the extras menu bar without ever seeing AXPopover.
        let elements = [
            FakeElement(id: 1, role: "AXMenuBar", parentID: nil),
            FakeElement(id: 2, role: "AXMenuBarItem", parentID: 1),
        ]
        XCTAssertNil(climb(from: 2, in: elements))
    }

    func testParentCycleTerminates() {
        // Defensive: AX parent links are app-provided and can be cyclic; the
        // hop bound must stop the climb rather than spin forever.
        let elements = [
            FakeElement(id: 1, role: "AXGroup", parentID: 2),
            FakeElement(id: 2, role: "AXGroup", parentID: 1),
        ]
        XCTAssertNil(climb(from: 1, in: elements))
    }

    func testMissingRoleKeepsClimbing() {
        let elements = [
            FakeElement(id: 1, role: "AXPopover", parentID: nil),
            FakeElement(id: 2, role: nil, parentID: 1),
        ]
        XCTAssertEqual(climb(from: 2, in: elements)?.id, 1)
    }
}
