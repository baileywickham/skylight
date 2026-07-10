import ApplicationServices
import XCTest
import SkylightCore

final class AXCaptureTests: XCTestCase {
    func testAXIdentityUsesCFEqualSemantics() {
        // Two AXUIElement refs for the same underlying element compare CFEqual.
        let a = AXUIElementCreateApplication(1) // launchd pid; element creation needs no permission
        let b = AXUIElementCreateApplication(1)
        let c = AXUIElementCreateApplication(99999)
        XCTAssertEqual(AXIdentity(element: a), AXIdentity(element: b))
        XCTAssertEqual(AXIdentity(element: a).hashValue, AXIdentity(element: b).hashValue)
        XCTAssertNotEqual(AXIdentity(element: a), AXIdentity(element: c))
    }

    func testCaptureWithoutAXPermissionThrowsPermissionDenied() throws {
        try XCTSkipIf(Permissions.status().accessibility, "runner unexpectedly has AX permission")
        let finder = try AppRegistry().resolve("com.apple.finder")
        XCTAssertThrowsError(try AXCapture().capture(app: finder, disableDiff: true)) { error in
            let e = error as? SkyServiceError
            XCTAssertEqual(e?.code, .permissionDenied)
            XCTAssertTrue(e?.message.contains("Privacy & Security > Accessibility") ?? false)
            // The message is the Permissions.instructions() accessibility line verbatim.
            let expected = Permissions.instructions(
                for: PermissionStatus(accessibility: false, screen_recording: true))
            XCTAssertEqual(e?.message, expected.joined(separator: " "))
        }
    }

    func testUnknownElementIndexIsStale() {
        XCTAssertThrowsError(try AXCapture().element(forIndex: 42, appPid: 1)) { error in
            XCTAssertEqual((error as? SkyServiceError)?.code, .staleElementIndex)
        }
    }

    // MARK: - Value sanitization (pure function; keeps one-node-per-line intact)

    func testSanitizeAXTextReplacesNewlinesAndControlCharacters() {
        XCTAssertEqual(sanitizeAXText("line one\nline two\r\nline three"),
                       "line one line two  line three")
        XCTAssertEqual(sanitizeAXText("tab\tbell\u{07}sep\u{2028}par\u{2029}end"),
                       "tab bell sep par end")
        XCTAssertFalse(sanitizeAXText("a\nb\nc").contains("\n"))
    }

    func testSanitizeAXTextCapsLengthWithEllipsis() {
        let long = String(repeating: "x", count: 500)
        let sanitized = sanitizeAXText(long)
        XCTAssertEqual(sanitized.count, 201) // 200 kept + "…" marker
        XCTAssertTrue(sanitized.hasSuffix("…"))
        // Short values pass through untouched.
        XCTAssertEqual(sanitizeAXText("hello"), "hello")
        XCTAssertEqual(sanitizeAXText(String(repeating: "y", count: 200)),
                       String(repeating: "y", count: 200))
    }
}
