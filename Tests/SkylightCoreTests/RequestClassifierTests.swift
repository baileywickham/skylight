import XCTest
@testable import SkylightCore

final class RequestClassifierTests: XCTestCase {
    private func classify(_ method: String, _ appKey: String?, background: Bool) -> RequestClass {
        RequestClassifier.classify(method: method, appKey: appKey, background: background)
    }

    func testMetaMethodsShareOneKeyAndNeverBlockOnActuation() {
        for method in ["ping", "echo", "list_apps", "capabilities"] {
            XCTAssertEqual(classify(method, nil, background: false), .keyed("$meta"), method)
            XCTAssertEqual(classify(method, "pid:42", background: true), .keyed("$meta"), method)
        }
    }

    /// Capture never activates an app, so it is per-app regardless of mode —
    /// but it does mutate that app's index map, so it is not free-for-all.
    func testReadOnlyMethodsAreKeyedInBothModes() {
        for method in ["get_app_state", "list_windows"] {
            XCTAssertEqual(classify(method, "pid:42", background: false), .keyed("pid:42"), method)
            XCTAssertEqual(classify(method, "pid:42", background: true), .keyed("pid:42"), method)
        }
    }

    func testBackgroundActionsAreKeyedPerApp() {
        for method in ["click", "press_key", "type_text", "scroll", "set_value", "drag",
                       "perform_secondary_action", "select_text"] {
            XCTAssertEqual(classify(method, "pid:42", background: true), .keyed("pid:42"), method)
        }
    }

    /// Foreground actions move the real cursor and change which app is
    /// frontmost — global state, so they must not overlap anything.
    func testForegroundActionsAreExclusive() {
        for method in ["click", "press_key", "type_text", "scroll", "set_value", "drag",
                       "perform_secondary_action", "select_text"] {
            XCTAssertEqual(classify(method, "pid:42", background: false), .exclusive, method)
        }
    }

    func testDifferentAppsGetDifferentKeys() {
        XCTAssertNotEqual(classify("click", "pid:42", background: true),
                          classify("click", "pid:43", background: true))
    }

    /// A request whose app could not be resolved is about to fail anyway;
    /// giving it a guessed key risks colliding with a real app's slot.
    func testUnresolvableTargetIsExclusive() {
        XCTAssertEqual(classify("click", nil, background: true), .exclusive)
        XCTAssertEqual(classify("get_app_state", nil, background: false), .exclusive)
    }

    /// Unknown methods fail safe: a future method that forgets to declare
    /// itself runs alone rather than racing.
    func testUnknownMethodIsExclusive() {
        XCTAssertEqual(classify("teleport", "pid:42", background: true), .exclusive)
    }
}
