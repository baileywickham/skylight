import XCTest
import SkylightCore

final class APITypesTests: XCTestCase {
    func testGetAppStateInputDefaults() throws {
        let input = try JSONDecoder().decode(GetAppStateInput.self, from: Data(#"{"app":"Notes"}"#.utf8))
        XCTAssertEqual(input.app, "Notes")
        XCTAssertNil(input.disableDiff)
        XCTAssertNil(input.include_data_url)
    }

    func testAppStateEncoding() throws {
        let state = AppState(
            text: "[0] AXWindow \"Untitled\"",
            screenshot: ScreenshotResult(url: "file:///tmp/x.png", data_url: nil, width: 800, height: 600),
            diffed: false)
        let json = String(data: try JSONEncoder().encode(state), encoding: .utf8)!
        XCTAssertTrue(json.contains(#""url":"file:\/\/\/tmp\/x.png""#) || json.contains(#""url":"file:///tmp/x.png""#))
        XCTAssertFalse(json.contains("data_url"))
    }

    func testAppStateAXOnlyOmitsScreenshotAndCarriesError() throws {
        let state = AppState(text: "[0] AXWindow", screenshot: nil,
                             screenshot_error: "permission_denied: Screen Recording not granted",
                             diffed: true)
        let data = try JSONEncoder().encode(state)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("\"screenshot\":"), "nil screenshot must be omitted from the wire")
        XCTAssertTrue(json.contains("\"screenshot_error\":"))
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testSelectTextInput() throws {
        let raw = #"{"app":"TextEdit","element_index":4,"text":"hello","selection_type":"cursor_after"}"#
        let input = try JSONDecoder().decode(SelectTextInput.self, from: Data(raw.utf8))
        XCTAssertEqual(input.selection_type, "cursor_after")
        XCTAssertNil(input.prefix)
    }

    func testSocketPathShape() {
        XCTAssertTrue(SkylightPaths.socketPath.hasSuffix("Library/Application Support/skylight/ipc/computeruse.sock"))
    }
}
