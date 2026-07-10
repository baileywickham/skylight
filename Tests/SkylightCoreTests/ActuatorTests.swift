import XCTest
import SkylightCore

final class ActuatorTests: XCTestCase {
    private func makeActuator(paused: Bool = false) throws -> Actuator {
        let pauseFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("SKYLIGHT_PAUSE-\(UUID())")
        if paused {
            FileManager.default.createFile(atPath: pauseFile.path, contents: nil)
        }
        return Actuator(registry: AppRegistry(), capture: AXCapture(),
                        postActionSleepMs: 0, pauseFile: pauseFile)
    }

    private func assertThrowsCode(_ code: SkyErrorCode, _ body: @autoclosure () throws -> ActionResult,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? SkyServiceError)?.code, code, file: file, line: line)
        }
    }

    func testPauseSentinelHaltsAllActuation() throws {
        let actuator = try makeActuator(paused: true)
        assertThrowsCode(.actuationPaused, try actuator.click(ClickInput(app: "Finder", element_index: 0)))
        assertThrowsCode(.actuationPaused, try actuator.typeText(TypeTextInput(app: "Finder", text: "x")))
        assertThrowsCode(.actuationPaused, try actuator.pressKey(PressKeyInput(app: "Finder", keys: "Return")))
    }

    func testUnknownAppIsAppNotFound() throws {
        let actuator = try makeActuator()
        assertThrowsCode(.appNotFound, try actuator.click(ClickInput(app: "Definitely Not An App 9000", element_index: 0)))
    }

    func testUnknownElementIndexIsStale() throws {
        let actuator = try makeActuator()
        assertThrowsCode(.staleElementIndex, try actuator.setValue(SetValueInput(app: "Finder", element_index: 777, value: "x")))
    }

    func testClickNeedsIndexOrCoordinates() throws {
        let actuator = try makeActuator()
        assertThrowsCode(.invalidParams, try actuator.click(ClickInput(app: "Finder")))
    }

    func testCoordinateClickWithoutPriorCaptureIsInvalid() throws {
        let actuator = try makeActuator()
        assertThrowsCode(.invalidParams, try actuator.click(ClickInput(app: "Finder", x: 10, y: 10)))
    }

    func testBadMouseButtonAndDirectionAreInvalidParams() throws {
        let actuator = try makeActuator()
        assertThrowsCode(.invalidParams, try actuator.click(ClickInput(app: "Finder", x: 1, y: 1, mouse_button: "chartreuse")))
        assertThrowsCode(.invalidParams, try actuator.scroll(ScrollInput(app: "Finder", element_index: 777, direction: "sideways", pages: 1)))
    }

    // MARK: - type_text UTF-16 chunking (surrogate-pair safety)

    private func isHighSurrogate(_ unit: UInt16) -> Bool { (0xD800...0xDBFF).contains(unit) }

    private func assertChunksWellFormed(_ text: String, maxUnits: Int = 20,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let chunks = utf16Chunks(text, maxUnits: maxUnits)
        for chunk in chunks {
            XCTAssertFalse(chunk.isEmpty, file: file, line: line)
            XCTAssertLessThanOrEqual(chunk.count, maxUnits + 1, file: file, line: line)
            XCTAssertFalse(isHighSurrogate(chunk.last!),
                           "chunk ends on a lone high surrogate — the pair was split across key events",
                           file: file, line: line)
        }
        let rejoined = String(utf16CodeUnits: chunks.flatMap { $0 }, count: chunks.reduce(0) { $0 + $1.count })
        XCTAssertEqual(rejoined, text, "chunks must concatenate back to the original text",
                       file: file, line: line)
    }

    func testUTF16ChunkingNeverSplitsASurrogatePairAtTheBoundary() {
        // 19 BMP units then an emoji (2 UTF-16 units): units[19] is the high
        // surrogate, exactly where the naive fixed-20 slice would cut the pair.
        assertChunksWellFormed(String(repeating: "a", count: 19) + "😀" + "tail")
        // Emoji fully occupying units 19-20 of every window: a run of pairs.
        assertChunksWellFormed(String(repeating: "a", count: 19) + String(repeating: "😀", count: 30))
        // Boundary at 20 exactly after a complete pair must NOT over-extend.
        assertChunksWellFormed(String(repeating: "a", count: 18) + "😀" + String(repeating: "b", count: 25))
    }

    func testUTF16ChunkingPlainAndEdgeInputs() {
        XCTAssertTrue(utf16Chunks("").isEmpty)
        XCTAssertEqual(utf16Chunks("short"), [Array("short".utf16)])
        assertChunksWellFormed(String(repeating: "x", count: 100)) // exact multiples
        assertChunksWellFormed(String(repeating: "😀", count: 3), maxUnits: 1) // every boundary is a pair
        // A 20-unit-aligned emoji keeps the chunk at 21 units, next chunk restarts cleanly.
        let chunks = utf16Chunks(String(repeating: "a", count: 19) + "😀" + "bc")
        XCTAssertEqual(chunks.map(\.count), [21, 2])
    }

    func testSelectTextOnUnknownIndexIsStale() throws {
        let actuator = try makeActuator()
        assertThrowsCode(.staleElementIndex, try actuator.selectText(SelectTextInput(
            app: "Finder", element_index: 777, text: "hello", selection_type: "select")))
    }

    // MARK: - scrollDeltas (one big wheel event is dropped often; bursts land)

    func testScrollDeltasSplitPreservesSumAndCapsSteps() {
        let down = scrollDeltas(total: -500, maxStep: 80)
        XCTAssertEqual(down.reduce(0, +), -500)
        XCTAssertTrue(down.allSatisfy { $0 < 0 && $0 >= -80 })
        XCTAssertEqual(down, [-80, -80, -80, -80, -80, -80, -20])

        let up = scrollDeltas(total: 165, maxStep: 80)
        XCTAssertEqual(up, [80, 80, 5])
    }

    func testScrollDeltasEdgeCases() {
        XCTAssertTrue(scrollDeltas(total: 0).isEmpty)
        XCTAssertEqual(scrollDeltas(total: 5, maxStep: 80), [5])   // below one step
        XCTAssertEqual(scrollDeltas(total: -80, maxStep: 80), [-80]) // exact multiple
    }

    // MARK: - Background mode (SKYLIGHT_BACKGROUND=1) decision logic

    func testShouldActivateOnlyInDefaultMode() {
        XCTAssertTrue(shouldActivate(background: false),
                      "default mode must keep the activation-first behavior")
        XCTAssertFalse(shouldActivate(background: true),
                       "background mode must never activate the target app")
    }

    func testEventDestinationRoutesPerPidOnlyInBackgroundMode() {
        XCTAssertEqual(eventDestination(background: false, targetPid: 4321), .session,
                       "default mode posts to the session tap (frontmost app)")
        XCTAssertEqual(eventDestination(background: true, targetPid: 4321), .pid(4321),
                       "background mode posts straight to the target app's pid")
    }

    func testBackgroundActuatorKeepsValidationAndPauseBehavior() throws {
        // Background mode changes only activation/delivery — guards run first
        // and are identical in both modes.
        let pauseFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("SKYLIGHT_PAUSE-\(UUID())")
        FileManager.default.createFile(atPath: pauseFile.path, contents: nil)
        let paused = Actuator(registry: AppRegistry(), capture: AXCapture(),
                              postActionSleepMs: 0, pauseFile: pauseFile, background: true)
        assertThrowsCode(.actuationPaused, try paused.click(ClickInput(app: "Finder", element_index: 0)))

        let live = Actuator(registry: AppRegistry(), capture: AXCapture(),
                            postActionSleepMs: 0,
                            pauseFile: FileManager.default.temporaryDirectory
                                .appendingPathComponent("SKYLIGHT_PAUSE-\(UUID())"),
                            background: true)
        assertThrowsCode(.appNotFound, try live.click(ClickInput(app: "Definitely Not An App 9000", element_index: 0)))
        assertThrowsCode(.invalidParams, try live.click(ClickInput(app: "Finder")))
    }

    func testEffectiveBackgroundPerRequestOverride() {
        let registry = AppRegistry()
        let capture = AXCapture()
        let fg = Actuator(registry: registry, capture: capture, background: false)
        let bg = Actuator(registry: registry, capture: capture, background: true)
        XCTAssertFalse(fg.effectiveBackground(nil), "no override: daemon default (foreground)")
        XCTAssertTrue(fg.effectiveBackground(true), "request opts INTO background")
        XCTAssertTrue(bg.effectiveBackground(nil), "no override: daemon default (background)")
        XCTAssertFalse(bg.effectiveBackground(false), "request opts OUT of background")
    }
}
