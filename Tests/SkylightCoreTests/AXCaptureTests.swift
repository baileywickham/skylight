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

    func testWindowListingsWithoutAXPermissionThrowsPermissionDenied() throws {
        try XCTSkipIf(Permissions.status().accessibility, "runner unexpectedly has AX permission")
        let finder = try AppRegistry().resolve("com.apple.finder")
        XCTAssertThrowsError(try AXCapture().windowListings(of: finder)) { error in
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

    // MARK: - Diff baseline commit (I1)
    //
    // `capture()` must NOT advance the diff baseline itself: the get_app_state
    // handler commits via `commitBaseline` only after the screenshot succeeds,
    // so a capture whose screenshot fails leaves the baseline (and coordinate
    // geometry) at the last tree the model actually received. Exercising
    // `capture()` end-to-end needs AX permission (TCC), so that path stays
    // smoke-only; these tests pin the contract of the separately-callable
    // commit step the handler relies on.

    private func makeCaptureResult(marker: String) -> CaptureResult {
        CaptureResult(
            text: "[0] AXWindow \"\(marker)\"",
            lines: [TreeLine(index: 0, depth: 0, text: "AXWindow \"\(marker)\"")],
            window: AXUIElementCreateApplication(1), // element creation needs no permission
            geometry: CaptureGeometry(windowOriginX: 10, windowOriginY: 20, scale: 2),
            diffed: false)
    }

    func testBaselineAdvancesOnlyWhenCommitted() {
        let capture = AXCapture()
        let pid: pid_t = 4242

        // The screenshot-failure path is "don't commit": baseline and geometry
        // must stay exactly as they were (here: absent).
        XCTAssertFalse(capture.hasBaseline(forPid: pid))
        XCTAssertNil(capture.latestGeometry(forPid: pid))

        let first = makeCaptureResult(marker: "seen-by-model")
        capture.commitBaseline(first, forPid: pid)
        XCTAssertTrue(capture.hasBaseline(forPid: pid))
        XCTAssertEqual(capture.latestGeometry(forPid: pid), first.geometry)

        // A later capture whose screenshot fails is never committed, so the
        // baseline/geometry must remain the last committed capture's.
        _ = makeCaptureResult(marker: "never-delivered")
        XCTAssertEqual(capture.latestGeometry(forPid: pid), first.geometry)

        let second = CaptureResult(
            text: first.text, lines: first.lines, window: first.window,
            geometry: CaptureGeometry(windowOriginX: 99, windowOriginY: 99, scale: 1),
            diffed: true)
        capture.commitBaseline(second, forPid: pid)
        XCTAssertEqual(capture.latestGeometry(forPid: pid), second.geometry)
    }

    func testCommitBaselineIsPerPid() {
        let capture = AXCapture()
        capture.commitBaseline(makeCaptureResult(marker: "a"), forPid: 1000)
        XCTAssertTrue(capture.hasBaseline(forPid: 1000))
        XCTAssertFalse(capture.hasBaseline(forPid: 2000))
        XCTAssertNil(capture.latestGeometry(forPid: 2000))
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

    // MARK: - Label fallback (pure function; SwiftUI/Calculator buttons expose
    // their name via AXDescription/AXHelp/AXIdentifier, not AXTitle)

    func testAXTitleWinsWhenPresent() {
        XCTAssertEqual(fallbackAXLabel(title: "Save", value: nil, description: "desc",
                                       help: "help", identifier: "id"), "Save")
        // A present title wins even when a value exists too.
        XCTAssertEqual(fallbackAXLabel(title: "Volume", value: "0.5", description: "d",
                                       help: nil, identifier: nil), "Volume")
    }

    func testFallbackOrderIsDescriptionThenHelpThenIdentifier() {
        XCTAssertEqual(fallbackAXLabel(title: nil, value: nil, description: "Seven",
                                       help: "h", identifier: "i"), "Seven")
        XCTAssertEqual(fallbackAXLabel(title: "", value: nil, description: nil,
                                       help: "Adds numbers", identifier: "i"), "Adds numbers")
        XCTAssertEqual(fallbackAXLabel(title: nil, value: "", description: "",
                                       help: nil, identifier: "equals"), "equals")
        XCTAssertNil(fallbackAXLabel(title: nil, value: nil, description: nil,
                                     help: nil, identifier: nil))
    }

    func testNoFallbackWhenValueAlreadyIdentifiesTheNode() {
        // A titleless node with a non-empty value renders `value="…"` already;
        // don't add a fallback label on top (keeps normal text fields unchanged).
        XCTAssertNil(fallbackAXLabel(title: nil, value: "hello world", description: "desc",
                                     help: "help", identifier: "id"))
    }

    func testFallbackAccessorsAreLazyWhenTitleResolves() {
        // The fallback attributes cost extra AX round-trips per node; they must
        // not be evaluated when the title already resolves.
        var touched = false
        func probe() -> String? { touched = true; return "x" }
        XCTAssertEqual(fallbackAXLabel(title: "Title", value: nil, description: probe(),
                                       help: probe(), identifier: probe()), "Title")
        XCTAssertFalse(touched)
    }

    // MARK: - Web-area retry predicate (Chromium first capture after enablement)

    func testNeedsWebAreaRetryOnlyRightAfterEnablement() {
        let noWeb = [TreeLine(index: 0, depth: 0, text: "[0] AXWindow \"Tab\"")]
        let withWeb = [TreeLine(index: 0, depth: 0, text: "[0] AXWindow \"Tab\""),
                       TreeLine(index: 1, depth: 1, text: "[1] AXWebArea")]
        XCTAssertTrue(needsWebAreaRetry(enablementJustApplied: true, lines: noWeb))
        XCTAssertFalse(needsWebAreaRetry(enablementJustApplied: true, lines: withWeb))
        XCTAssertFalse(needsWebAreaRetry(enablementJustApplied: false, lines: noWeb))
        XCTAssertFalse(needsWebAreaRetry(enablementJustApplied: false, lines: withWeb))
    }
}
