import XCTest
@testable import SkylightCore

final class ElementFinderTests: XCTestCase {
    private let tree = FixtureNode("w", "AXWindow", title: "Untitled", kids: [
        FixtureNode("t", "AXToolbar", kids: [
            FixtureNode("save", "AXButton", title: "Save"),
            FixtureNode("share", "AXButton", title: "Share"),
        ]),
        FixtureNode("side", "AXGroup", title: "Sidebar", kids: [
            FixtureNode("g", "AXGroup", kids: [FixtureNode("row", "AXStaticText", value: "Saved items")]),
        ]),
    ])

    func testQueryNormalizesRoleAndText() {
        XCTAssertEqual(ElementQuery(role: "button", text: "SAVE"), ElementQuery(role: "AXButton", text: "save"))
        XCTAssertTrue(ElementQuery(role: " ", text: "").isEmpty)
        let q = ElementQuery(role: "button", text: "sav")
        XCTAssertTrue(q.matches(role: "AXButton", title: "Save", value: nil))
        XCTAssertFalse(q.matches(role: "AXStaticText", title: nil, value: "Saved"))
        XCTAssertTrue(ElementQuery(role: nil, text: "items").matches(role: "AXStaticText", title: nil, value: "Saved items"))
    }

    func testFindsByRoleAndTextWithTheSameIndicesACaptureWouldAssign() {
        let map = ElementIndexMap()
        let serialized = AXTreeSerializer().serialize(root: tree, map: map)
        let saveIndex = serialized.lines.first { $0.text.contains("\"Save\"") }!.index
        let outcome = findElements(root: tree, query: ElementQuery(role: "button", text: "save"), map: map)
        XCTAssertEqual(outcome.matches.map(\.element_index), [saveIndex])
        XCTAssertEqual(outcome.matches.first?.line, "[\(saveIndex)] AXButton \"Save\"")
        XCTAssertEqual(outcome.matches.first?.ancestors, "AXWindow \"Untitled\"")
        XCTAssertFalse(outcome.truncated)
    }

    func testAncestorsSkipAnonymousGroups() {
        let outcome = findElements(root: tree, query: ElementQuery(role: nil, text: "saved"), map: ElementIndexMap())
        XCTAssertEqual(outcome.matches.count, 1)
        XCTAssertEqual(outcome.matches.first?.ancestors, "AXWindow \"Untitled\" > AXGroup \"Sidebar\"")
    }

    func testMatchesAreImmediatelyActionableWithoutInvalidatingEarlierIndices() {
        let map = ElementIndexMap()
        _ = AXTreeSerializer().serialize(root: tree, map: map)
        let outside = map.index(for: AnyHashable("w"))
        // A scoped find (the toolbar only) must not mark the rest stale.
        let toolbar = tree.kids[0]
        let outcome = findElements(root: toolbar, query: ElementQuery(role: "button", text: nil), map: map)
        XCTAssertEqual(outcome.matches.count, 2)
        XCTAssertTrue(outcome.matches.allSatisfy { map.isInLatestCapture($0.element_index) })
        XCTAssertTrue(map.isInLatestCapture(outside))
    }

    func testLimitTruncatesAndCapsBoundTheWalk() {
        let limited = findElements(root: tree, query: ElementQuery(role: "button", text: nil),
                                   map: ElementIndexMap(), limit: 1)
        XCTAssertEqual(limited.matches.count, 1)
        XCTAssertTrue(limited.truncated)
        let shallow = findElements(root: tree, query: ElementQuery(role: "button", text: nil),
                                   map: ElementIndexMap(), caps: TreeCaps(maxDepth: 1, maxNodes: 100))
        XCTAssertEqual(shallow.matches.count, 0)
        XCTAssertEqual(shallow.lines.count, 1)
        XCTAssertEqual(findResultLimit(nil), 50)
        XCTAssertEqual(findResultLimit(0), 1)
        XCTAssertEqual(findResultLimit(10_000), maxFindResults)
    }

    /// The display value is capped at 200 characters; text search must still
    /// see the rest of it (verified live: "line 120" in a long TextEdit area).
    func testTextSearchSeesPastTheDisplayCap() {
        struct LongNode: TreeNode {
            var identity: AnyHashable { "long" }
            var role: String { "AXTextArea" }
            var title: String? { nil }
            var value: String? { "line 1…" }
            var searchValue: String? { "line 1 … line 120" }
            var children: [any TreeNode] { [] }
        }
        let outcome = findElements(root: LongNode(), query: ElementQuery(role: nil, text: "line 120"), map: ElementIndexMap())
        XCTAssertEqual(outcome.matches.count, 1)
        XCTAssertEqual(outcome.matches.first?.value, "line 1…") // the line still shows the display copy
    }

    func testMenuSelectNeedsTheAppActiveButOtherAXActionsDoNot() {
        XCTAssertTrue(needsAppActive(action: .menuSelect))
        XCTAssertTrue(needsAppActive(action: .typeText))
        XCTAssertFalse(needsAppActive(action: .elementClick))
        XCTAssertFalse(deliversSyntheticEvents(action: .menuSelect))
    }

    func testMenuTitlesMatchIgnoringCaseSpaceAndEllipsisStyle() {
        XCTAssertEqual(normalizedMenuTitle(" Export As... "), normalizedMenuTitle("Export As…"))
        XCTAssertEqual(normalizedMenuTitle("FILE"), "file")
    }

    func testScrollBarTargetMovesOnePageOfTheScrollableRange() throws {
        // 1000pt of content in a 250pt view: range 750, one page = 1/3.
        XCTAssertEqual(try XCTUnwrap(scrollBarTarget(current: 0, visible: 250, content: 1000, pages: 1, towardEnd: true)),
                       1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(scrollBarTarget(current: 0.9, visible: 250, content: 1000, pages: 1, towardEnd: true), 1)
        XCTAssertEqual(scrollBarTarget(current: 0.1, visible: 250, content: 1000, pages: 2, towardEnd: false), 0)
        XCTAssertNil(scrollBarTarget(current: 0, visible: 300, content: 300, pages: 1, towardEnd: true))
    }
}

final class WaitForTests: XCTestCase {
    func testElementConditionAndItsInverse() {
        XCTAssertTrue(waitConditionMet(elementMatches: 1, windowMatched: nil, gone: false, stable: nil))
        XCTAssertFalse(waitConditionMet(elementMatches: 0, windowMatched: nil, gone: false, stable: nil))
        XCTAssertTrue(waitConditionMet(elementMatches: 0, windowMatched: nil, gone: true, stable: nil))
        XCTAssertFalse(waitConditionMet(elementMatches: 2, windowMatched: nil, gone: true, stable: nil))
    }

    func testEveryRequestedConditionMustHold() {
        XCTAssertFalse(waitConditionMet(elementMatches: 1, windowMatched: false, gone: false, stable: nil))
        XCTAssertTrue(waitConditionMet(elementMatches: 1, windowMatched: true, gone: false, stable: true))
        XCTAssertFalse(waitConditionMet(elementMatches: 1, windowMatched: true, gone: false, stable: false))
        // Stability is never inverted by gone.
        XCTAssertTrue(waitConditionMet(elementMatches: 0, windowMatched: nil, gone: true, stable: true))
        XCTAssertTrue(waitConditionMet(elementMatches: nil, windowMatched: nil, gone: false, stable: true))
    }

    func testTimeoutDefaultsAndStaysUnderTheRequestTimeout() {
        XCTAssertEqual(waitTimeoutMs(nil), 5_000)
        XCTAssertEqual(waitTimeoutMs(-5), 0)
        XCTAssertEqual(waitTimeoutMs(600_000), 25_000)
    }
}

final class ModifierParsingTests: XCTestCase {
    func testParsesModifierNamesLikeChords() throws {
        XCTAssertEqual(try parseModifiers(nil), [])
        XCTAssertEqual(try parseModifiers(""), [])
        XCTAssertEqual(try parseModifiers("cmd"), .maskCommand)
        XCTAssertEqual(try parseModifiers("Shift+Option"), [.maskShift, .maskAlternate])
    }

    func testRejectsNonModifierKeys() {
        XCTAssertThrowsError(try parseModifiers("cmd+a")) { error in
            XCTAssertEqual((error as? SkyServiceError)?.code, .invalidParams)
        }
    }
}

final class LocateApplicationTests: XCTestCase {
    func testFindsAnAppByNameInTheGivenDirectoriesCaseInsensitively() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("My Tool.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = AppRegistry()
        XCTAssertEqual(registry.locateApplication("my tool", directories: [dir])?.lastPathComponent, "My Tool.app")
        XCTAssertEqual(registry.locateApplication("My Tool.app", directories: [dir])?.lastPathComponent, "My Tool.app")
        XCTAssertNil(registry.locateApplication("Nope", directories: [dir]))
        let path = dir.appendingPathComponent("My Tool.app").path
        XCTAssertEqual(registry.locateApplication(path, directories: [])?.path, path)
    }
}
