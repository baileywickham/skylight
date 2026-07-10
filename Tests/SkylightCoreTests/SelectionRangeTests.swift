import Foundation
import XCTest
import SkylightCore

final class SelectionRangeTests: XCTestCase {
    func testSelectMatchRange() throws {
        let range = try resolveSelectionRange(in: "the quick brown fox", text: "quick",
                                              prefix: nil, suffix: nil, selectionType: "select")
        XCTAssertEqual(range, NSRange(location: 4, length: 5))
    }

    func testCursorBeforeCollapsesToStart() throws {
        let range = try resolveSelectionRange(in: "the quick brown fox", text: "quick",
                                              prefix: nil, suffix: nil, selectionType: "cursor_before")
        XCTAssertEqual(range, NSRange(location: 4, length: 0))
    }

    func testCursorAfterCollapsesToEnd() throws {
        let range = try resolveSelectionRange(in: "the quick brown fox", text: "quick",
                                              prefix: nil, suffix: nil, selectionType: "cursor_after")
        XCTAssertEqual(range, NSRange(location: 9, length: 0))
    }

    func testPrefixSuffixDisambiguateAmbiguousMatch() throws {
        // "and" appears twice; prefix "peanut " picks the second.
        let range = try resolveSelectionRange(in: "sand and peanut and jelly", text: "and",
                                              prefix: "peanut ", suffix: nil, selectionType: "select")
        XCTAssertEqual(range, NSRange(location: 16, length: 3))
    }

    func testSuffixDisambiguatesAmbiguousMatch() throws {
        // Same value; suffix " jelly" also picks the second "and". The returned
        // range covers only the text itself, never the suffix.
        let range = try resolveSelectionRange(in: "sand and peanut and jelly", text: "and",
                                              prefix: nil, suffix: " jelly", selectionType: "select")
        XCTAssertEqual(range, NSRange(location: 16, length: 3))
    }

    func testCursorAfterWithPrefixExcludesPrefixFromRangeMath() throws {
        let range = try resolveSelectionRange(in: "sand and peanut and jelly", text: "and",
                                              prefix: "peanut ", suffix: nil, selectionType: "cursor_after")
        XCTAssertEqual(range, NSRange(location: 19, length: 0))
    }

    func testOffsetsAreUTF16CodeUnits() throws {
        // kAXSelectedTextRangeAttribute counts UTF-16 code units: the emoji is
        // 2 units, so "fox" starts at 3 (not the Character offset 2).
        let range = try resolveSelectionRange(in: "👍 fox trot", text: "fox",
                                              prefix: nil, suffix: nil, selectionType: "select")
        XCTAssertEqual(range, NSRange(location: 3, length: 3))
    }

    func testTextNotFoundThrows() {
        XCTAssertThrowsError(try resolveSelectionRange(in: "hello world", text: "xyz",
                                                       prefix: nil, suffix: nil, selectionType: "select")) { error in
            XCTAssertEqual((error as? SkyServiceError)?.code, .elementNotActionable)
        }
    }

    func testPrefixMismatchThrowsEvenWhenTextExists() {
        XCTAssertThrowsError(try resolveSelectionRange(in: "hello world", text: "world",
                                                       prefix: "goodbye ", suffix: nil, selectionType: "select")) { error in
            XCTAssertEqual((error as? SkyServiceError)?.code, .elementNotActionable)
        }
    }

    func testUnknownSelectionTypeThrows() {
        XCTAssertThrowsError(try resolveSelectionRange(in: "hello", text: "he",
                                                       prefix: nil, suffix: nil, selectionType: "sideways")) { error in
            XCTAssertEqual((error as? SkyServiceError)?.code, .invalidParams)
        }
    }
}
